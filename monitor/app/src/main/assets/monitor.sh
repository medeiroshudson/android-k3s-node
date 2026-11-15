#!/system/bin/sh
# k3s-node monitor collector.
#
# Prints ONE JSON object per invocation. Runs as root (the app calls it through
# su) and is split in sections so the app can poll each at its own cadence:
#
#   monitor.sh host       every 2 s   (/proc, battery, thermal, disk)
#   monitor.sh container  every 5 s   (droidspaces + systemd inside the container)
#   monitor.sh cluster    every 15 s  (node readiness, capacity, usage, pods)
#
# Deliberately shell: one root call per cycle instead of a fork per metric, and
# the whole contract can be tested from adb without building the app.
#
# Forks are the cost here, not bytes read: every `cat`, `grep` or `df` in a $( )
# spawns a process. Each section therefore makes one pass per source and splits
# the result with shell parameter expansion instead of calling out again.

export PATH=/sbin:/system/bin:/system/xbin:/vendor/bin:$PATH

SECTION="${1:-host}"
DS=/data/local/Droidspaces/bin/droidspaces
CONTAINER="${CONTAINER:-k3s-mobile-1}"

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
num_or_null() { [ -n "$1" ] && printf '%s' "$1" || printf 'null'; }

# `droidspaces --json show` is read once per run: each field lookup used to fork
# it again, and the container cycle needed seven of them.
ds_out=""
load_ds() { [ -n "$ds_out" ] || ds_out="$("$DS" --json show 2>/dev/null)"; }
ds_field() {
    load_ds
    printf '%s' "$ds_out" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" | head -1
}
container_running() { load_ds; printf '%s' "$ds_out" | grep -q "\"name\":\"$CONTAINER\""; }

# Runs one command string inside the container; every call costs a full
# droidspaces round trip, so sections batch everything into a single call.
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
    # One awk over memory info instead of four greps.
    set -- $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2}
                  /^SwapFree:/{sf=$2} END{print t, a, st, sf}' /proc/meminfo)
    mem_total=$1; mem_avail=$2; swap_total=$3; swap_free=$4

    load1=$(cut -d' ' -f1 /proc/loadavg)
    psi_full=$(sed -n 's/.*full avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory 2>/dev/null)
    cores=$(grep -c ^processor /proc/cpuinfo)

    # One cat for all 85 thermal zones; 85 forks per cycle was most of the cost.
    # The hottest zone is the SoC one - battery zones read far lower.
    temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null |
        awk '$1 + 0 > 1000 { if ($1 + 0 > m) m = $1 + 0 } END { if (m > 0) printf "%.1f", m / 1000 }')
    [ -n "$temp" ] && temp_c=$temp || temp_c=null

    set -- $(cat /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/temp 2>/dev/null)
    bat_pct=$1; bat_temp=$2
    bat_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    [ -n "$bat_temp" ] && bat_temp_c=$(awk -v t="$bat_temp" 'BEGIN{printf "%.1f", t/10}') || bat_temp_c=null

    set -- $(df -k /data 2>/dev/null | tail -1)
    data_total=$2; data_free=$4

    printf '{"ts":%s,"host":{"load1":%s,"cpu_pct":%s,"cpu_cores":%s,' \
        "$(date +%s)" "$(num_or_null "$load1")" "$(cpu_pct)" "$(num_or_null "$cores")"
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

    # Cores, disk and service states in a single round trip, separated by "~":
    # mksh (Android's /system/bin/sh) reads "|" as alternation inside ${var%%|*},
    # where the split silently returns an empty string.
    # /proc/cpuinfo, not nproc: nproc reports the affinity mask of the calling
    # process and answered 6 and 7 on an 8-core phone.
    body=$(in_container '
        c=$(grep -c ^processor /proc/cpuinfo)
        set -- $(df -k / | tail -1)
        s=""
        for x in k3s-agent docker ssh tailscaled; do s="$s$x=$(systemctl is-active $x 2>/dev/null) "; done
        printf "%s~%s %s~%s" "$c" "$2" "$4" "$s"')

    cores=${body%%~*}
    rest=${body#*~}
    disk_part=${rest%%~*}
    services=${rest#*~}
    disk_total=${disk_part%% *}
    disk_free=${disk_part##* }

    printf '{"ts":%s,"container":{"name":%s,"state":"running","pid":%s,"uptime_sec":%s,' \
        "$(date +%s)" "$(json_str "$CONTAINER")" "$(num_or_null "$pid")" "$(num_or_null "$uptime")"
    printf '"cpu_permill":%s,"cpu_limit_permill":%s,"cpu_cores":%s,' \
        "$(num_or_null "$cpu_permill")" "$(num_or_null "$cpu_limit")" "$(num_or_null "$cores")"
    printf '"ram_used_kb":%s,"ram_limit_kb":%s,' \
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

    # One round trip for the whole cluster view: capacity and readiness of every
    # node (one listing, so they cannot disagree), usage from metrics-server and
    # the pod tally.
    body=$(in_container '
        printf "@@nodes\n"
        kubectl get nodes --no-headers -o custom-columns="N:.metadata.name,R:.status.conditions[?(@.type==\"Ready\")].status,C:.status.capacity.cpu,M:.status.capacity.memory,V:.status.nodeInfo.kubeletVersion" 2>/dev/null
        printf "@@top\n"
        kubectl top nodes --no-headers 2>/dev/null
        printf "@@pods\n"
        kubectl get pods -A --no-headers 2>/dev/null')

    # Capacity is aggregated twice: over every node, and over the nodes
    # metrics-server actually answers for. The percentage is then computed
    # against the measured capacity, so it is never read as the whole cluster
    # when only part of it is scraped.
    agg=$(printf '%s\n' "$body" | awk -v want="$CONTAINER" '
        function cores(v,   n,u) {
            if (v == "") return 0
            u = v; sub(/[0-9.]+/, "", u)
            n = v; sub(/[a-zA-Z]+$/, "", n)
            if (u == "n") return n / 1000000000
            if (u == "u") return n / 1000000
            if (u == "m") return n / 1000
            return n + 0
        }
        function kib(v,   n,u) {
            if (v == "") return 0
            u = v; sub(/[0-9.]+/, "", u)
            n = v; sub(/[a-zA-Z]+$/, "", n)
            if (u == "Ki") return n + 0
            if (u == "Mi") return n * 1024
            if (u == "Gi") return n * 1048576
            return n / 1024
        }
        /^@@nodes/ { sec = "nodes"; next }
        /^@@top/   { sec = "top"; next }
        /^@@pods/  { sec = "pods"; next }
        sec == "nodes" && NF >= 5 {
            cpu[$1] = cores($3); mem[$1] = kib($4)
            nodes++
            if ($2 == "True") ready_nodes++
            cap_cpu += cores($3); cap_mem += kib($4)
            if ($1 == want) { node_ready = $2; node_version = $5 }
            next
        }
        sec == "top" && NF >= 5 && $2 ~ /^[0-9.]+[mun]?$/ {
            # only lines with real numbers: a node metrics-server cannot scrape
            # prints <unknown> and is not coverage
            reporting++
            used_cpu += cores($2); used_mem += kib($4)
            rep_cpu += cpu[$1];     rep_mem += mem[$1]
            measured = measured (measured == "" ? "" : ",") $1
            next
        }
        sec == "pods" && NF >= 4 {
            pods_total++
            if ($4 == "Running") pods_running++
        }
        END {
            printf "%d %d %d %.2f %.0f %.2f %.0f %.2f %.0f %d %d %s %s %s", nodes,
                   ready_nodes, reporting, cap_cpu, cap_mem, rep_cpu, rep_mem,
                   used_cpu, used_mem, pods_total, pods_running,
                   (node_ready == "" ? "unknown" : node_ready),
                   (node_version == "" ? "" : node_version),
                   (measured == "" ? "" : measured)
        }')

    set -- $agg
    [ "${12}" = "True" ] && ready_js=true || ready_js=false

    printf '{"ts":%s,"cluster":{"node":%s,"ready":%s,"pods_total":%s,"pods_running":%s,"k3s_version":%s,' \
        "$(date +%s)" "$(json_str "$CONTAINER")" "$ready_js" \
        "$(num_or_null "${10}")" "$(num_or_null "${11}")" "$(json_str "${13}")"
    printf '"nodes_total":%s,"nodes_ready":%s,"nodes_reporting":%s,' \
        "$(num_or_null "$1")" "$(num_or_null "$2")" "$(num_or_null "$3")"
    printf '"cpu_capacity_cores":%s,"mem_capacity_kb":%s,' \
        "$(num_or_null "$4")" "$(num_or_null "$5")"
    printf '"cpu_measured_cores":%s,"mem_measured_kb":%s,' \
        "$(num_or_null "$6")" "$(num_or_null "$7")"
    printf '"cpu_used_cores":%s,"mem_used_kb":%s,' \
        "$(num_or_null "$8")" "$(num_or_null "$9")"
    # metrics-server cannot scrape every kubelet here, so the usage belongs to a
    # subset. Name the subset: a percentage without provenance reads as the whole
    # cluster when it is in fact one node.
    printf '"measured_nodes":%s}}\n' "$(json_str "${14}")"
    ;;

*)
    echo "usage: $0 [host|container|cluster]" >&2
    exit 2
    ;;
esac
