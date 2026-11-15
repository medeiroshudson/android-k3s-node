#!/usr/bin/env bash
# Install the boot hook: /system/etc/init/k3s-mobile.rc plus the supervisor in
# /data/adb/service.d/. See docs/boot.md for why this path and not Magisk's.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

ROOT="$(cd .. && pwd)"
RC_SRC="$ROOT/android/system/etc/init/k3s-mobile.rc"
SUP_SRC="$ROOT/android/data/adb/service.d/k3s-mobile-1.sh"

require_device
require_root

for f in "$RC_SRC" "$SUP_SRC"; do
    [ -f "$f" ] || die "missing file: $f"
done

say "installing the supervisor"
tmp_sup="$(push_tmp "$SUP_SRC")"
run_root "mkdir -p /data/adb/service.d"
run_root "cp $tmp_sup $SUPERVISOR"
run_root "chmod 755 $SUPERVISOR"
ok "$SUPERVISOR"

say "installing the init service"
tmp_rc="$(push_tmp "$RC_SRC")"
run_root "mount -o rw,remount /" || die "could not remount / read-write"
run_root "cp $tmp_rc $RC"
run_root "chmod 644 $RC"
run_root "chown root:root $RC"
run_root "sync"
run_root "mount -o ro,remount /"
ok "$RC"

say "installed"
printf '  reload requires a reboot; the service starts on sys.boot_completed:\n    adb reboot\n'
