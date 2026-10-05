#!/bin/sh
#
# Program: pgenerator_usb_restore.sh
#
# First-boot settings rescue. A re-flashed image carries
# /etc/BiasiLinux/BiasiLinux.FirstBoot until rcPGenerator consumes it,
# so this is the one moment we know the device is factory-fresh. If a
# USB stick holding a .pgbackup (exported from the WebUI, or written by
# 'usb-export') is plugged in, restore it before the daemon's first
# start: the user flashes the card, plugs the stick, powers on, and the
# box comes back with their settings, profiles and calibration history.
#
# Safe by construction:
#  - no first-boot marker  -> exit (normal boot, never touch settings)
#  - no USB stick          -> exit
#  - no/invalid .pgbackup  -> exit; the helper validates the archive
#    (format, manifest, per-file sha256) BEFORE writing anything, and
#    a wrong-board or foreign archive can only fail validation.
#  - restore writes exactly the backup's file list, and the helper
#    takes a rollback snapshot under /var/lib/PGenerator/system-backups
#    before applying.
# A marker file records the attempt either way so exactly one rescue
# runs per flashed image; re-flashing restores the trigger.
#
# Called by rcPGenerator AFTER the disk resize and BEFORE the PGenerator
# daemon starts. Root. Logs to /tmp so the (ephemeral) log never
# outlives into a restored state; the durable trail is the rollback
# snapshot plus a one-line marker.

FIRST_BOOT_FILE="/etc/BiasiLinux/BiasiLinux.FirstBoot"
ATTEMPT_MARKER="/etc/BiasiLinux/usb-restore.attempted"
BACKUP_HELPER="/usr/bin/pgenerator_system_backup.py"
PYTHON_BIN="$(command -v python3 || command -v python)"
LOG=/tmp/pgenerator-usb-restore.log

log() {
 echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null
}

if [ ! -f "$FIRST_BOOT_FILE" ]; then
 exit 0
fi
if [ -f "$ATTEMPT_MARKER" ]; then
 exit 0
fi
if [ ! -f "$BACKUP_HELPER" ] || [ -z "$PYTHON_BIN" ]; then
 exit 0
fi

# Give the stick a moment after power-on; USB storage can enumerate
# well after rcS reaches this point, especially behind a hub.
i=0
while [ "$i" -lt 10 ]; do
 if ls /dev/sd[a-z] >/dev/null 2>&1; then
  break
 fi
 sleep 1
 i=$((i + 1))
done
if ! ls /dev/sd[a-z] >/dev/null 2>&1; then
 log "no USB storage after 10s; skipping rescue"
 exit 0
fi

log "first boot with USB storage present; attempting restore"
# Current software version straight from version.pm (same parse as
# pgenerator-update); "unknown" keeps the rollback snapshot label honest.
VERSION="$(grep '^\$version=' /usr/share/PGenerator/version.pm 2>/dev/null | sed 's/.*="\([^"]*\)".*/\1/')"
[ -n "$VERSION" ] || VERSION="unknown"
"$PYTHON_BIN" "$BACKUP_HELPER" usb-restore --version "$VERSION" >> "$LOG" 2>&1
rc=$?
# Mark the attempt on both success and failure: a corrupt stick must not
# make every future boot stall here. To retry the rescue deliberately,
# remove /etc/BiasiLinux/usb-restore.attempted and reboot.
echo "rc=$rc" > "$ATTEMPT_MARKER" 2>/dev/null
if [ "$rc" -eq 0 ]; then
 log "restore completed; the box boots with the backup's settings"
 sync
else
 log "restore did not apply (rc=$rc); booting factory defaults"
fi
exit 0
