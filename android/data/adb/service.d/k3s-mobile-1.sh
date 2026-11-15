#!/system/bin/sh
# Supervisor for the k3s-mobile-1 Droidspaces container, started by
# /system/etc/init/k3s-mobile.rc as a long-running (non-oneshot) init service.
#
# Why a supervisor instead of a fire-and-forget start:
#  - init SIGKILLs a oneshot service's whole process group when its main process
#    exits, which took the Droidspaces monitor down with it;
#  - keeping the service alive gives a free watchdog: if the container dies, the
#    next tick brings it back.
# Why not Magisk's service.d: on this Magisk 31.1 build the bundled busybox is
# broken (execve fails with "Exec format error") and Magisk re-extracts it every
# boot, so no service.d or module script ever runs.

BIN=/data/local/Droidspaces/bin/droidspaces
CONF=/data/local/Droidspaces/Containers/k3s-mobile-1/container.config
LOG=/data/local/Droidspaces/Logs/service-d-k3s-mobile-1.log

[ -x "$BIN" ] || exit 0
[ -f "$CONF" ] || exit 0

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date +%F' '%T) $*" >> "$LOG"; }

ensure_running() {
    if "$BIN" show 2>/dev/null | grep -q "k3s-mobile-1"; then
        return 0
    fi
    log "k3s-mobile-1 not running, starting"
    "$BIN" --conf="$CONF" start >> "$LOG" 2>&1
}

# Give Android a moment to settle before loop-mounting the 24G rootfs image.
sleep 15
log "supervisor up"
ensure_running

while true; do
    sleep 60
    ensure_running
done
