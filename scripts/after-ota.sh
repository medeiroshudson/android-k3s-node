#!/usr/bin/env bash
# Re-apply everything a LineageOS OTA removes (/system/etc/cgroups.json and the
# init service), reboot, and verify the node.
#
#   ./after-ota.sh --check    # detect what is missing, write nothing
#   ./after-ota.sh --apply    # re-apply, reboot, wait for Ready, verify
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

MODE="--check"
[ "${1:-}" = "--apply" ] && MODE="--apply"

require_device

# An OTA replaces boot.img, so Magisk (and therefore root) can be gone. Nothing
# here can fix that: the patched boot image has to be produced by the Magisk app.
if ! run_root 'id' 2>/dev/null | grep -q 'uid=0'; then
    warn "no root shell: this OTA probably removed Magisk"
    cat <<'EOT'

  Manual step required:
    1. pull the OTA's boot.img and patch it in the Magisk app (Install -> Select and Patch a File)
    2. flash the patched image:  heimdall flash --BOOT magisk_patched-*.img
    3. reboot, confirm `adb shell su -c id` returns uid=0, then re-run: make after-ota
EOT
    exit 1
fi
ok "root available"

say "detecting what is missing"
need_override=0
need_hook=0
mem_hier="$(run_root 'grep ^memory /proc/cgroups' 2>/dev/null | awk '{print $2}' || true)"
if [ "${mem_hier:-0}" = "0" ] || [ -z "${mem_hier:-}" ]; then
    warn "memory is not on cgroup v1"
    need_override=1
else
    ok "memory already on cgroup v1"
fi
file_exists "$CGROUPS_JSON" && ok "$CGROUPS_JSON present" || { warn "$CGROUPS_JSON missing"; need_override=1; }
file_exists "$RC" && ok "$RC present" || { warn "$RC missing"; need_hook=1; }
file_exists "$SUPERVISOR" && ok "$SUPERVISOR present" || { warn "$SUPERVISOR missing"; need_hook=1; }

if [ "$MODE" = "--check" ]; then
    say "check only - nothing written (need_override=$need_override need_hook=$need_hook)"
    exit 0
fi

if [ "$need_override" -eq 1 ]; then
    say "re-applying the cgroups override"
    ./apply-system-overrides.sh --apply
fi

if [ "$need_hook" -eq 1 ]; then
    say "re-installing the boot hook"
    ./install-boot-hook.sh
fi

if [ "$need_override" -eq 0 ] && [ "$need_hook" -eq 0 ]; then
    say "overrides already in place - only verifying"
    ./verify-node.sh
    exit $?
fi

say "rebooting and waiting for the node"
"$ADB" reboot
sleep 20
for _ in $(seq 1 40); do
    booted="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    [ "$booted" = "1" ] && break
    sleep 3
done
[ "${booted:-}" = "1" ] || die "device did not finish booting"

# the supervisor waits 15 s after boot_completed, then k3s joins
sleep 90
./verify-node.sh
