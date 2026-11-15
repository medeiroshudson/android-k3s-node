#!/usr/bin/env bash
# Shared helpers for the android-k3s-node scripts.
set -euo pipefail

ADB="${ADB:-adb}"
SU="${SU:-/debug_ramdisk/su}"
CONTAINER="${CONTAINER:-k3s-mobile-1}"
CONFIG="/data/local/Droidspaces/Containers/${CONTAINER}/container.config"
DS_BIN="/data/local/Droidspaces/bin/droidspaces"
RC="/system/etc/init/k3s-mobile.rc"
SUPERVISOR="/data/adb/service.d/k3s-mobile-1.sh"
CGROUPS_JSON="/system/etc/cgroups.json"
CGROUPS_BACKUP="/sdcard/cgroups.json.orig"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_device() {
    "$ADB" get-state >/dev/null 2>&1 || die "no adb device connected"
    ok "device: $("$ADB" get-serialno)"
}

# Run a command as root on the device. The command must not contain single quotes.
run_root() {
    "$ADB" shell "$SU -c '$1'"
}

require_root() {
    run_root 'id' 2>/dev/null | grep -q 'uid=0' \
        || die "no root shell. If the OTA removed Magisk, re-patch boot.img first."
}

file_exists() {
    run_root "test -f $1 && echo yes" 2>/dev/null | grep -q yes
}

push_tmp() {
    local src="$1" tmp="/data/local/tmp/$(basename "$1")"
    "$ADB" push "$src" "$tmp" >/dev/null
    printf '%s' "$tmp"
}
