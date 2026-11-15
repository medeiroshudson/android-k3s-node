#!/usr/bin/env bash
# Check that the device really is a working k3s node.
#
#   ./verify-node.sh            # full check
#   NODE=k3s-mobile-1 ./verify-node.sh
#
# Exits non-zero on the first failure, printing what to fix.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

NODE="${NODE:-$CONTAINER}"
fail=0

say "system override"
if file_exists "$CGROUPS_JSON"; then ok "$CGROUPS_JSON present"; else warn "missing - run make apply-override"; fail=1; fi

say "memory cgroup"
mem_line="$(run_root 'grep ^memory /proc/cgroups' 2>/dev/null || true)"
mem_hier="$(printf '%s' "$mem_line" | awk '{print $2}')"
if [ "${mem_hier:-0}" != "0" ] && [ -n "${mem_hier:-}" ]; then
    ok "memory on cgroup v1 (hierarchy $mem_hier)"
else
    warn "memory is not a v1 hierarchy (got: ${mem_line:-none}) - override missing or not applied"; fail=1
fi

if run_root 'cat /sys/fs/cgroup/cgroup.controllers' 2>/dev/null | grep -qw memory; then
    warn "memory still listed in the v2 root"; fail=1
else
    ok "memory absent from the v2 root"
fi

if run_root 'test -r /dev/memcg/memory.limit_in_bytes' 2>/dev/null; then
    ok "/dev/memcg readable"
else
    warn "/dev/memcg missing"; fail=1
fi

say "boot hook"
if file_exists "$RC"; then ok "$RC present"; else warn "missing - run make install-hook"; fail=1; fi
if file_exists "$SUPERVISOR"; then ok "$SUPERVISOR present"; else warn "missing - run make install-hook"; fail=1; fi

say "container"
if run_root "$DS_BIN show" 2>/dev/null | grep -q "$CONTAINER"; then
    ok "container $CONTAINER running"
else
    warn "container $CONTAINER not running"; fail=1
fi

say "agent inside the container"
if run_root "$DS_BIN --name=$CONTAINER run -- systemctl is-active k3s-agent" 2>/dev/null | grep -q '^active'; then
    ok "k3s-agent active"
else
    warn "k3s-agent not active"; fail=1
fi

say "cluster"
if command -v kubectl >/dev/null 2>&1; then
    status="$(kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    if [ "$status" = "True" ]; then
        ok "node $NODE Ready"
        kubectl get node "$NODE" -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type 2>/dev/null | tail -1
    else
        warn "node $NODE is not Ready (got: ${status:-not found})"; fail=1
    fi
else
    warn "kubectl not found on PATH - skipping the cluster check"
fi

if [ "$fail" -ne 0 ]; then
    printf '\n\033[1;31mverification failed\033[0m - see docs/operations.md\n'
    exit 1
fi
printf '\n\033[1;32mall checks passed\033[0m\n'
