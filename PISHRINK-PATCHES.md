# PiShrink — Patched Fork (v0.1.5-fixes)

Patched Version von [Drewsif/PiShrink](https://github.com/Drewsif/PiShrink).
Datei: `pishrink.sh` (gleiches Verzeichnis).

## Verwendung

```bash
chmod +x pishrink.sh
sudo ./pishrink.sh [-adhnrsvzZS] imagefile.img [newimagefile.img]
```

Flags:

| Flag | Wirkung |
|------|---------|
| `-s` | Filesystem NICHT beim ersten Boot expandieren |
| `-v` | Verbose |
| `-n` | Keinen Update-Check gegen GitHub fahren |
| `-r` | Erweiterte FS-Repair-Option benutzen, falls die normale failed |
| `-z` | Nach dem Shrink mit gzip komprimieren |
| `-Z` | Nach dem Shrink mit xz komprimieren |
| `-S` | Nach dem Shrink mit zstd komprimieren (**neu**) |
| `-a` | Komprimierung parallel über alle Cores (pigz / xz -T0 / zstd -T0) |
| `-d` | Debug-Log nach `./pishrink.log` schreiben |
| `-h` | Hilfe |

Env-Overrides für Compressor-Optionen:
```bash
PISHRINK_GZIP="-9"    sudo ./pishrink.sh -z ...
PISHRINK_XZ="-T0 -9e" sudo ./pishrink.sh -Z ...
PISHRINK_ZSTD="-T0 -22 --ultra --long" sudo ./pishrink.sh -S ...
```

Beispiele:
```bash
# Schnell + klein: parallel zstd, Output mit angegebenem Namen
sudo ./pishrink.sh -avS rpi-os.img /backup/rpi-os.img

# Sicherste Variante: Repair + Debug-Log
sudo ./pishrink.sh -rd rpi-os.img
```

---

## Was wurde gefixt — Original vs. Patched

### Echte Bugs

| # | Original | Patched |
|---|----------|---------|
| 1 | `ZIPTOOLS=("gzip xz")` — Array mit **einem** Element `"gzip xz"`, Membership-Check funktioniert nur per Substring-Zufall | `ZIPTOOLS=("gzip" "xz" "zstd")` + exakter Match `[[ " ${ZIPTOOLS[*]} " =~ \ ${ziptool}\  ]]` |
| 2 | `if [[ $? ]]` im Update-Check — immer wahr, Warnung kommt auch bei kaputtem curl | `curl -fsSL` + `[[ -n "$latest_release" && "$latest_release" > "$version" ]]` |
| 3 | `return -1` in `raspi_config_expand` — bash kann das nicht, wird zu 255 | `return 1` |
| 4 | Versionsstring `v26.03.16` (YY.MM.DD) bricht den String-Vergleich mit `v0.1.x`-Tags | `v0.1.5-fixes` |
| 5 | `truncate -s "$endresult"` ohne Sanity-Check — könnte Image vergrößern statt verkleinern | Check `if (( endresult < current_bytes ))` davor |
| 6 | Einrückung in `checkFilesystem` außerhalb des Funktionsblocks | Begradigt |
| 7 | `getopts` mit leading `:` für Silent-Mode, aber kein `\?)`-Branch | `\?)` mit sauberer Fehlermeldung ergänzt |

### Robustheit

| # | Original | Patched |
|---|----------|---------|
| 8 | Kein `pipefail` — Pipelines failen still | `set -o pipefail` aktiv |
| 9 | `cleanup()` macht nur `losetup -d`, mountdir bleibt liegen | `cleanup()` unmountet (mit `-l` als Fallback), löscht tmp-Dir, ist null-safe |
| 10 | `partprobe + sleep 3` (Race Condition) | `udevadm settle` (mit `sleep 1` Fallback) |
| 11 | `ls -lh "$img" \| cut -d ' ' -f 5` — fragil bei Locale/Spaces | `human_size()` via `stat -c %s` + `numfmt --to=iec` |
| 12 | `grep "$partstart" \| grep logical` (grep\|grep-Anti-Pattern) | Single `awk` |
| 13 | `REQUIRED_TOOLS` als space-separated String | Bash-Array, Iteration über `"${REQUIRED_TOOLS[@]}"` |
| 14 | `command -v $command` unquoted | `command -v "$cmd"` |
| 15 | `error()` schreibt auf stdout | `error()` schreibt auf stderr |
| 16 | `losetup` ohne Fehlercheck | `if ! losetup ...; then exit 6` |

### Modernisierung im Autoexpand (rc.local-Snippet)

| # | Original | Patched |
|---|----------|---------|
| 17 | Hardcoded `mmcblk0` — bricht auf Pi 5 mit NVMe oder USB-Boot | Dynamische Erkennung via `findmnt -n -o SOURCE /` + `lsblk -no PKNAME` |
| 18 | Hardcoded `mmcblk0p` Stripping für Partition Number | Trailing-digit-Regex (`grep -oE '[0-9]+$'`) — funktioniert für `mmcblk0p2`, `nvme0n1p2`, `sda2` |
| 19 | Fragiler `fdisk`-Heredoc als einziger Pfad | `sfdisk -N "$PART_NUM" "$DISK"` wenn verfügbar (deterministisch), `fdisk` als Fallback |

### Neue Features

- **zstd-Support**: `-S` Flag. Spürbar schneller als xz bei vergleichbarer Größe; mit `-a` parallel über alle Cores.
- **`numfmt`/`findmnt`/`lsblk`** als neue Required-Tools (alle Coreutils/util-linux, auf jedem Debian/Raspbian default da).

---

## Bewusst NICHT geändert

- **Volles `set -euo pipefail`**: hätte den kompletten Error-Handling-Stil (`if (( $? ))`-Pattern überall) umbauen lassen müssen. Mit nur `pipefail` bleibt das Diff klein und nachvollziehbar.
- **systemd-Unit statt `/etc/rc.local`**: rc.local ist auf modernen Pi OS (Bookworm) deprecated, aber compat-Service ist noch da. Ein `firstboot-resize.service` als Drop-in wäre möglich — aber das wäre ein größerer Umbau und würde Pi-OS-Bullseye-und-älter brechen.
- **Original Exit-Codes** beibehalten, damit existierende Automation/Wrapper-Skripte nicht brechen.

---

## Testen vor Produktiv-Einsatz

```bash
# 1. Syntax-Check
bash -n pishrink.sh

# 2. Trockenlauf mit kleinem Test-Image
dd if=/dev/zero of=test.img bs=1M count=200
sudo parted -s test.img mklabel msdos mkpart primary ext4 1MiB 100%
sudo losetup -fP test.img
sudo mkfs.ext4 /dev/loop0p1   # ggf. anpassen
sudo losetup -d /dev/loop0

sudo ./pishrink.sh -avS test.img test_shrunk.img.zst
ls -la test_shrunk.img.zst

# 3. Mit echtem Image
sudo ./pishrink.sh -avZ /pfad/zum/rpi-backup.img /backup/rpi-shrunk.img
```

## Lizenz

Original: PiShrink von Drew Bonasera (Drewsif), GPL-3.0.
Diese Patches: gleiche Lizenz.
