#!/system/bin/sh
# k3s-node monitor collector.
#
# Prints ONE JSON object per invocation. Runs as root (the app calls it through
# su) and is split in sections so the app can poll each at its own cadence:
#
#   monitor.sh host       every 2 s   (/proc, battery, thermal, disk)
#   monitor.sh container  every 5 s   (droidspaces + systemd inside the container)
#   monitor.sh cluster    every 15 s  (k3s node readiness and pod counts)
#
# Deliberately shell: one root call per cycle instead of a fork per metric, and
# the whole contract can be tested from adb without building the app.

export PATH=/sbin:/system/bin:/system/xbin:/vendor/bin:/data/local/Droidspaces/bin:$PATH

SECTION="${1:-host}"
DS=/data/local/Droidspaces/bin/droidspaces
CONTAINER="${CONTAINER:-k3s-mobile-1}"

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
num_or_null() { [ -n "$1" ] && printf '%s' "$1" || printf 'null'; }

# Reads one key out of the flat JSON printed by `droidspaces --json show`.
ds_field() {
    ds_json | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" | head -1
}

ds_json() { "$DS" --json show 2>/dev/null; }

container_running() { ds_json | grep -q "\"name\":\"$CONTAINER\""; }

# Runs a command inside the container and prints its stdout.
in_container() {
    "$DS" --name="$CONTAINER" run -- /bin/sh -c "$1" 2>/dev/null
}

# Reads the aggregate cpu line and prints "<total> <idle>" jiffies.
# /proc/stat starts with the literal label, then user nice system idle iowait
# irq softirq steal - the label must be consumed or the arithmetic silently
# fails and every sample looks idle.
cpu_sample() {
    read -r _ u n s i w irq si st _ < /proc/stat
    echo "$((u + n + s + i + w + irq + si + st)) $((i + w))"
}

cpu_pct() {
    # Two samples 200 ms apart: instant utilisation, no state carried between calls.
    set -- $(cpu_sample)
    t1=$1; i1=$2
    sleep 0.2
    set -- $(cpu_sample)
    t2=$1; i2=$2
    dt=$((t2 - t1)); di=$((i2 - i1))
    [ "$dt" -gt 0 ] && echo $((100 * (dt - di) / dt)) || echo 0
}

case "$SECTION" in
host)
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    load1=$(cut -d' ' -f1 /proc/loadavg)
    psi_full=$(sed -n 's/.*full avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory 2>/dev/null)

    # hottest thermal zone, ignoring the battery zones
    temp=""
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        t=$(cat "$z" 2>/dev/null)
        [ -n "$t" ] || continue
        [ "$t" -gt 1000 ] 2>/dev/null || continue
        if [ -n "$temp" ] && [ "$t" -le "$temp" ]; then continue; fi
        temp=$t
    done
    [ -n "$temp" ] && temp_c=$(awk -v t="$temp" 'BEGIN{printf "%.1f", t/1000}') || temp_c=null

    bat_pct=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    bat_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    bat_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    [ -n "$bat_temp" ] && bat_temp_c=$(awk -v t="$bat_temp" 'BEGIN{printf "%.1f", t/10}') || bat_temp_c=null

    set -- $(df -k /data 2>/dev/null | tail -1)
    data_total=$2; data_free=$4

    printf '{"ts":%s,"host":{"load1":%s,"cpu_pct":%s,"cpu_cores":%s,' \
        "$(date +%s)" "$(num_or_null "$load1")" "$(cpu_pct)" "$(num_or_null "$(nproc)")"
    printf '"mem_total_kb":%s,"mem_avail_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s,' \
        "$(num_or_null "$mem_total")" "$(num_or_null "$mem_avail")" \
        "$(num_or_null "$swap_total")" "$(num_or_null "$swap_free")"
    printf '"psi_full10":%s,"temp_c":%s,"battery_pct":%s,"battery_status":%s,"battery_temp_c":%s,' \
        "$(num_or_null "$psi_full")" "$temp_c" "$(num_or_null "$bat_pct")" \
        "$(json_str "$bat_status")" "$bat_temp_c"
    printf '"data_total_kb":%s,"data_free_kb":%s}}\n' \
        "$(num_or_null "$data_total")" "$(num_or_null "$data_free")"
    ;;

container)
    if ! container_running; then
        printf '{"ts":%s,"container":{"name":%s,"state":"stopped"}}\n' \
            "$(date +%s)" "$(json_str "$CONTAINER")"
        exit 0
    fi

    pid=$(ds_field pid)
    uptime=$(ds_field uptime_sec)
    ram_used=$(ds_field ram_used_kb)
    ram_limit=$(ds_field ram_limit_kb)
    cpu_permill=$(ds_field cpu_permill)
    cpu_limit=$(ds_field cpu_limit_permill)

    disk=$(in_container 'df -k / | tail -1 | awk "{print \$2, \$4}"')
    disk_total=$(printf '%s' "$disk" | cut -d' ' -f1)
    disk_free=$(printf '%s' "$disk" | cut -d' ' -f2)

    services=$(in_container 'for s in k3s-agent docker ssh tailscaled; do printf "%s=%s " "$s" "$(systemctl is-active $s 2>/dev/null)"; done')

    printf '{"ts":%s,"container":{"name":%s,"state":"running","pid":%s,"uptime_sec":%s,' \
        "$(date +%s)" "$(json_str "$CONTAINER")" "$(num_or_null "$pid")" "$(num_or_null "$uptime")"
    printf '"cpu_permill":%s,"cpu_limit_permill":%s,"ram_used_kb":%s,"ram_limit_kb":%s,' \
        "$(num_or_null "$cpu_permill")" "$(num_or_null "$cpu_limit")" \
        "$(num_or_null "$ram_used")" "$(num_or_null "$ram_limit")"
    printf '"disk_total_kb":%s,"disk_free_kb":%s,"services":%s}}\n' \
        "$(num_or_null "$disk_total")" "$(num_or_null "$disk_free")" \
        "$(json_str "$services")"
    ;;

cluster)
    if ! container_running; then
        printf '{"ts":%s,"cluster":{"node":%s,"ready":false,"error":"container stopped"}}\n' \
            "$(date +%s)" "$(json_str "$CONTAINER")"
        exit 0
    fi

    node=$(in_container "kubectl get node $CONTAINER --no-headers 2>/dev/null")
    ready=$(printf '%s' "$node" | awk '{print $2}')
    version=$(printf '%s' "$node" | awk '{print $5}')
    pods_total=$(in_container 'kubectl get pods -A --no-headers 2>/dev/null | wc -l' | tr -d ' ')
    pods_running=$(in_container 'kubectl get pods -A --no-headers 2>/dev/null | grep -c Running' | tr -d ' ')

    [ "$ready" = "Ready" ] && ready_js=true || ready_js=false

    printf '{"ts":%s,"cluster":{"node":%s,"ready":%s,"pods_total":%s,"pods_running":%s,"k3s_version":%s}}\n' \
        "$(date +%s)" "$(json_str "$CONTAINER")" "$ready_js" \
        "$(num_or_null "$pods_total")" "$(num_or_null "$pods_running")" \
        "$(json_str "$version")"
    ;;

*)
    echo "usage: $0 [host|container|cluster]" >&2
    exit 2
    ;;
esac
