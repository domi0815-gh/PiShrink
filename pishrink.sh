#!/usr/bin/env bash

# Project: PiShrink (patched fork)
# Description: PiShrink is a bash script that automatically shrinks a Pi image
#              that will then resize to the max size of the SD/NVMe on boot.
# Upstream:    https://github.com/Drewsif/PiShrink
#
# Patches in this version vs. upstream v0.1.x:
#   * ZIPTOOLS array fix (was a single concatenated element)
#   * Broken update-check condition fixed (if [[ $? ]] is always true)
#   * return -1 -> return 1
#   * REQUIRED_TOOLS converted to a proper bash array
#   * set -o pipefail for early failure detection in pipelines
#   * cleanup() now also unmounts $mountdir and removes the tmp dir
#   * udevadm settle replaces sleep-based syncs
#   * size readouts via stat + numfmt (no more ls -lh | cut)
#   * grep|grep anti-pattern replaced with single awk
#   * command -v properly quoted
#   * zstd support (-S flag), incl. parallel mode
#   * autoexpand rc.local now detects mmcblk*, nvme*, sd* automatically
#   * truncate-shrink only runs if it would actually shrink
#   * Fixed indentation in checkFilesystem
#   * getopts now reports invalid option cleanly

set -o pipefail

version="v0.1.5-fixes"
startSeconds=$SECONDS

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"

REQUIRED_TOOLS=(parted losetup tune2fs md5sum e2fsck resize2fs findmnt lsblk numfmt)

ZIPTOOLS=("gzip" "xz" "zstd")
declare -A ZIP_PARALLEL_TOOL=(   [gzip]="pigz" [xz]="xz"     [zstd]="zstd"          )
declare -A ZIP_PARALLEL_OPTIONS=([gzip]="-f9"  [xz]="-T0"    [zstd]="-T0 -19 --long")
declare -A ZIPEXTENSIONS=(       [gzip]="gz"   [xz]="xz"     [zstd]="zst"           )

# Default state (so cleanup never references unset vars under set -u, if ever enabled)
mountdir=""
loopback=""
src=""
img=""

function info() {
	echo "$SCRIPTNAME: $1"
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occurred in line $1: " >&2
	shift
	echo "$@" >&2
}

function cleanup() {
	if [[ -n "$mountdir" ]] && mountpoint -q "$mountdir" 2>/dev/null; then
		umount "$mountdir" 2>/dev/null || umount -l "$mountdir" 2>/dev/null || true
	fi
	if [[ -n "$mountdir" && -d "$mountdir" ]]; then
		rmdir "$mountdir" 2>/dev/null || true
	fi
	if [[ -n "$loopback" ]] && losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [[ "$debug" == true && -n "$src" && -f "$LOGFILE" ]]; then
		local old_owner
		old_owner=$(stat -c %u:%g "$src" 2>/dev/null) || return 0
		chown "$old_owner" "$LOGFILE" 2>/dev/null || true
	fi
}

function logVariables() {
	if [[ "$debug" == true ]]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function human_size() {
	# Print file size in human-readable form using stat+numfmt.
	# Falls back to du -h if numfmt is missing for any reason.
	local f="$1"
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec --suffix=B "$(stat -c %s "$f")"
	else
		du -h "$f" | awk '{print $1}'
	fi
}

function checkFilesystem() {
	info "Checking filesystem"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return

	if [[ "$repair" == true ]]; then
		info "Trying to recover corrupted filesystem - Phase 2"
		e2fsck -fy -b 32768 "$loopback"
		(( $? < 4 )) && return
	fi
	error $LINENO "Filesystem recoveries failed. Giving up..."
	exit 9
}

function set_autoexpand() {
	# Make Pi expand rootfs on next boot
	mountdir=$(mktemp -d)
	partprobe "$loopback" 2>/dev/null || true
	command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 1
	umount "$loopback" > /dev/null 2>&1 || true

	if ! mount "$loopback" "$mountdir" -o rw; then
		info "Unable to mount loopback, autoexpand will not be enabled"
		return
	fi

	if [[ ! -d "$mountdir/etc" ]]; then
		info "/etc not found, autoexpand will not be enabled"
		umount "$mountdir"
		return
	fi

	if [[ ! -f "$mountdir/etc/rc.local" ]]; then
		info "An existing /etc/rc.local was not found, autoexpand may fail..."
	fi

	if ! grep -q "## PiShrink https://github.com/Drewsif/PiShrink ##" "$mountdir/etc/rc.local" 2>/dev/null; then
		echo "Creating new /etc/rc.local"
		if [[ -f "$mountdir/etc/rc.local" ]]; then
			mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
		fi

cat <<'EOFRC' > "$mountdir/etc/rc.local"
#!/bin/bash
## PiShrink https://github.com/Drewsif/PiShrink ##
do_expand_rootfs() {
  # Determine root device dynamically (works for mmcblk0p2, nvme0n1p2, sda2, ...)
  ROOT_PART=$(findmnt -n -o SOURCE /)
  ROOT_PART_NAME=${ROOT_PART#/dev/}
  ROOT_DISK_NAME=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null)
  ROOT_DISK="/dev/${ROOT_DISK_NAME}"

  if [ -z "$ROOT_DISK_NAME" ]; then
    echo "Could not determine root disk for $ROOT_PART. Giving up."
    return 0
  fi

  # Partition number = trailing digits of the partition name
  PART_NUM=$(echo "$ROOT_PART_NAME" | grep -oE '[0-9]+$')
  if [ -z "$PART_NUM" ]; then
    echo "Could not determine partition number from $ROOT_PART_NAME"
    return 0
  fi

  # Prefer sfdisk if available (deterministic), otherwise fall back to fdisk heredoc.
  if command -v sfdisk >/dev/null 2>&1; then
    echo ",+" | sfdisk -N "$PART_NUM" "$ROOT_DISK" || true
  else
    PART_START=$(parted "$ROOT_DISK" -ms unit s p | grep "^${PART_NUM}:" | cut -f 2 -d: | sed 's/[^0-9]//g')
    [ "$PART_START" ] || return 1
    fdisk "$ROOT_DISK" <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START

p
w
EOF
  fi

cat <<EOF > /etc/rc.local &&
#!/bin/sh
echo "Expanding $ROOT_PART"
resize2fs $ROOT_PART
rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local

EOF
reboot
exit
}
raspi_config_expand() {
  /usr/bin/env raspi-config --expand-rootfs
  if [[ $? != 0 ]]; then
    return 1
  else
    rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local
    reboot
    exit
  fi
}
raspi_config_expand
echo "WARNING: Using backup expand..."
sleep 5
do_expand_rootfs
echo "ERROR: Expanding failed..."
sleep 5
if [[ -f /etc/rc.local.bak ]]; then
  cp -fp /etc/rc.local.bak /etc/rc.local
  /etc/rc.local
fi
exit 0
EOFRC

		chmod +x "$mountdir/etc/rc.local"
	fi
	umount "$mountdir"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhnrsvzZS] imagefile.img [newimagefile.img]

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -n         Disable automatic update checking
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -S         Compress image after shrinking with zstd
  -a         Compress image in parallel using multiple cores
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

should_skip_autoexpand=false
debug=false
update_check=true
repair=false
parallel=false
verbose=false
ziptool=""

while getopts ":adnhrsvzZS" opt; do
  case "${opt}" in
    a) parallel=true ;;
    d) debug=true ;;
    n) update_check=false ;;
    h) help ;;
    r) repair=true ;;
    s) should_skip_autoexpand=true ;;
    v) verbose=true ;;
    z) ziptool="gzip" ;;
    Z) ziptool="xz" ;;
    S) ziptool="zstd" ;;
    \?) error $LINENO "Unknown option: -$OPTARG"; help ;;
    *) help ;;
  esac
done
shift $((OPTIND-1))

if [[ "$debug" == true ]]; then
	info "Creating log file $LOGFILE"
	rm -f "$LOGFILE" &>/dev/null || true
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo -e "PiShrink $version - https://github.com/Drewsif/PiShrink\n"

# Try to check for updates
if $update_check; then
  if command -v curl >/dev/null 2>&1; then
    latest_release=$(curl -fsSL -m 5 https://api.github.com/repos/Drewsif/PiShrink/releases/latest 2>/dev/null \
                     | grep -i '"tag_name"' \
                     | awk -F '"' '{print $4}')
    if [[ -n "$latest_release" && "$latest_release" > "$version" ]]; then
      echo "WARNING: You do not appear to be running the latest version of PiShrink. Head over to https://github.com/Drewsif/PiShrink to grab $latest_release"
      echo ""
    fi
  fi
fi

# Args
src="$1"
img="$1"

# Usage checks
if [[ -z "$img" ]]; then
  help
fi

if [[ ! -f "$img" ]]; then
  error $LINENO "$img is not a file..."
  exit 2
fi
if (( EUID != 0 )); then
  error $LINENO "You need to be running as root."
  exit 3
fi

# Set locale to POSIX(English) temporarily.
# These locale settings only affect the script and its sub-processes.
export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX

# Check selected compression tool is supported and add its binary to REQUIRED_TOOLS
if [[ -n "$ziptool" ]]; then
	if [[ ! " ${ZIPTOOLS[*]} " =~ \ ${ziptool}\  ]]; then
		error $LINENO "$ziptool is an unsupported ziptool."
		exit 17
	fi
	if [[ "$parallel" == true ]]; then
		REQUIRED_TOOLS+=( "${ZIP_PARALLEL_TOOL[$ziptool]}" )
	else
		REQUIRED_TOOLS+=( "$ziptool" )
	fi
fi

# Check that what we need is installed
for cmd in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error $LINENO "$cmd is not installed."
    exit 4
  fi
done

# Copy to new file if requested
if [[ -n "$2" ]]; then
  f="$2"
  if [[ -n "$ziptool" && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then
    # Remove zip extension if compression requested; the zip tool would otherwise complain.
    f="${f%.*}"
  fi
  info "Copying $1 to $f..."
  if ! cp --reflink=auto --sparse=always "$1" "$f"; then
    error $LINENO "Could not copy file..."
    exit 5
  fi
  old_owner=$(stat -c %u:%g "$1")
  chown "$old_owner" "$f"
  img="$f"
fi

# Cleanup at script exit
trap cleanup EXIT

# Gather info
info "Gathering data"
beforesize="$(human_size "$img")"
if ! parted_output="$(parted -ms "$img" unit B print)"; then
	rc=$?
	error $LINENO "parted failed with rc $rc"
	info "Possibly invalid image. Run 'parted $img unit B print' manually to investigate"
	exit 6
fi
partnum="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 1)"
partstart="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')"

# Single-pass detection of primary vs. logical partition
if parted -s "$img" unit B print | awk -v ps="$partstart" '$0 ~ ps && /logical/ {found=1} END {exit !found}'; then
    parttype="logical"
else
    parttype="primary"
fi

if ! loopback="$(losetup -f --show -o "$partstart" "$img")"; then
	error $LINENO "losetup failed"
	exit 6
fi

if ! tune2fs_output="$(tune2fs -l "$loopback")"; then
	rc=$?
	echo "$tune2fs_output"
	error $LINENO "tune2fs failed with rc $rc. Unable to shrink this type of image"
	exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:'  | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart parttype tune2fs_output currentsize blocksize

# Check if we should make Pi expand rootfs on next boot
if [[ "$parttype" == "logical" ]]; then
  echo "WARNING: PiShrink does not yet support autoexpanding of this type of image"
elif [[ "$should_skip_autoexpand" == false ]]; then
  set_autoexpand
else
  echo "Skipping autoexpanding process..."
fi

# Make sure filesystem is OK
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
	rc=$?
	error $LINENO "resize2fs failed with rc $rc"
	exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize
if [[ "$currentsize" -eq "$minsize" ]]; then
  info "Filesystem already shrunk to smallest size. Skipping filesystem shrinking"
else
  # Add some free space to the end of the filesystem
  extra_space=$((currentsize - minsize))
  logVariables $LINENO extra_space
  for space in 5000 1000 100; do
    if (( extra_space > space )); then
      minsize=$((minsize + space))
      break
    fi
  done
  logVariables $LINENO minsize

  # Shrink filesystem
  info "Shrinking filesystem"
  if [[ -z "$mountdir" ]]; then
    mountdir=$(mktemp -d)
  fi

  if ! resize2fs -p "$loopback" "$minsize"; then
    rc=$?
    error $LINENO "resize2fs failed with rc $rc"
    mount "$loopback" "$mountdir" 2>/dev/null \
      && mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local" 2>/dev/null \
      && umount "$mountdir"
    losetup -d "$loopback"
    exit 12
  fi

  info "Zeroing any free space left"
  mount "$loopback" "$mountdir"
  cat /dev/zero > "$mountdir/PiShrink_zero_file" 2>/dev/null || true
  if [[ -f "$mountdir/PiShrink_zero_file" ]]; then
    info "Zeroed $(human_size "$mountdir/PiShrink_zero_file")"
    rm -f "$mountdir/PiShrink_zero_file"
  fi
  umount "$mountdir"

  command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 1

  # Shrink partition
  info "Shrinking partition"
  partnewsize=$((minsize * blocksize))
  newpartend=$((partstart + partnewsize))
  logVariables $LINENO partnewsize newpartend

  if ! parted -s -a minimal "$img" rm "$partnum"; then
    rc=$?
    error $LINENO "parted failed with rc $rc"
    exit 13
  fi

  if ! parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"; then
    rc=$?
    error $LINENO "parted failed with rc $rc"
    exit 14
  fi
fi

# Truncate the image file
info "Checking for unpartitioned space"
if ! endresult=$(parted -ms "$img" unit B print free); then
  rc=$?
  error $LINENO "parted failed with rc $rc"
  exit 15
fi

endresult_last=$(tail -1 <<< "$endresult")
if [[ "$endresult_last" == *free\; ]]; then
  endresult=$(cut -d ':' -f 2 <<< "$endresult_last" | tr -d 'B')
  current_bytes=$(stat -c %s "$img")
  logVariables $LINENO endresult current_bytes
  if (( endresult < current_bytes )); then
    info "Truncating image"
    if ! truncate -s "$endresult" "$img"; then
      rc=$?
      error $LINENO "truncate failed with rc $rc"
      exit 16
    fi
  else
    info "No truncation needed (endresult >= current size)"
  fi
fi

# Handle compression
if [[ -n "$ziptool" ]]; then
	options=""
	envVarname="${MYNAME^^}_${ziptool^^}" # e.g. PISHRINK_GZIP / PISHRINK_XZ / PISHRINK_ZSTD
	[[ "$parallel" == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
	[[ -v $envVarname ]] && options="${!envVarname}"
	[[ "$verbose" == true ]] && options="$options -v"

	if [[ "$parallel" == true ]]; then
		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
		info "Using $parallel_tool on the shrunk image"
		# shellcheck disable=SC2086
		if ! $parallel_tool $options "$img"; then
			rc=$?
			error $LINENO "$parallel_tool failed with rc $rc"
			exit 18
		fi
	else
		info "Using $ziptool on the shrunk image"
		# shellcheck disable=SC2086
		if ! $ziptool $options "$img"; then
			rc=$?
			error $LINENO "$ziptool failed with rc $rc"
			exit 19
		fi
	fi
	img="$img.${ZIPEXTENSIONS[$ziptool]}"
fi

aftersize=$(human_size "$img")
logVariables $LINENO aftersize

finishSeconds=$SECONDS
elapsedSeconds=$((finishSeconds - startSeconds))
info "Shrunk $img from $beforesize to $aftersize in $((elapsedSeconds / 60))m $((elapsedSeconds % 60))s"
