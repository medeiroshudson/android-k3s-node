#!/usr/bin/env bash
# Install /system/etc/cgroups.json (memory back on cgroup v1) on the device.
#
#   ./apply-system-overrides.sh --check    # report state, change nothing
#   ./apply-system-overrides.sh --apply    # back up, validate, write, reboot-less
#
# Needs / writable. On this device that is `mount -o rw,remount /` (no dm-verity);
# on a verity-enforcing device use `adb disable-verity` + `adb remount` or rebuild
# the super image.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd ../android/system/etc && pwd)/cgroups.json"
MODE="--check"
[ "${1:-}" = "--apply" ] && MODE="--apply"

require_device
require_root

say "current state"
run_root 'grep ^memory /proc/cgroups || true'
run_root 'cat /sys/fs/cgroup/cgroup.controllers || true'

if [ "$MODE" = "--check" ]; then
    say "check only - nothing written"
    if file_exists "$CGROUPS_JSON"; then
        ok "$CGROUPS_JSON present ($(run_root "wc -c < $CGROUPS_JSON" | tr -d ' ') bytes)"
    else
        warn "$CGROUPS_JSON missing"
    fi
    exit 0
fi

say "validating the new file on this host"
python3 -m json.tool "$SRC" >/dev/null || die "invalid JSON in $SRC - refusing to write"
ok "JSON valid"

say "backing up the current file"
if file_exists "$CGROUPS_JSON" && ! file_exists "$CGROUPS_BACKUP"; then
    run_root "cp $CGROUPS_JSON $CGROUPS_BACKUP"
    ok "backup at $CGROUPS_BACKUP"
else
    warn "backup already present or current file missing - keeping what is there"
fi

tmp="$(push_tmp "$SRC")"
ok "pushed to $tmp"

say "writing $CGROUPS_JSON"
run_root "mount -o rw,remount /" || die "could not remount / read-write"
run_root "cp $tmp $CGROUPS_JSON"
run_root "chmod 644 $CGROUPS_JSON"
run_root "chown root:root $CGROUPS_JSON"
run_root "sync"
run_root "mount -o ro,remount /"
ok "written ($(run_root "wc -c < $CGROUPS_JSON" | tr -d ' ') bytes)"

say "next step"
printf '  reboot for the override to take effect:\n    adb reboot && sleep 60 && ./verify-node.sh\n'
