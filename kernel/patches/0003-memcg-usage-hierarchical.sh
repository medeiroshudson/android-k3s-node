#!/usr/bin/env bash
# CONFIG_MEMCG_HEIMDALL makes memory.usage_in_bytes report the cgroup's own RSS
# instead of the hierarchical page counter:
#
#   static unsigned long mem_cgroup_usage(struct mem_cgroup *memcg, bool swap)
#   {
#   ...
#   #ifdef CONFIG_MEMCG_HEIMDALL
#           val = memcg_page_state(memcg, MEMCG_RSS);
#   #else
#           val = page_counter_read(&memcg->memory);
#   #endif
#
# The page counter keeps the real hierarchical total; only this readout is local.
# On this device the container root reported 26 MB of "usage" while its counter
# watermark (memory.max_usage_in_bytes) had peaked at 900 MB. The kubelet reads
# usage_in_bytes for node memory and for every container, so it reported node
# memory as 0 and metrics-server had no valid value to publish for k3s-mobile-1.
#
# Keeping the HEIMDALL block everywhere else (memory.force_shrink, the reclaim
# loop cap) and using the hierarchical counter only here restores correct
# accounting with a minimal blast radius.
#
# Usage: 0003-memcg-usage-hierarchical.sh <kernel-tree>
set -euo pipefail

KDIR="${1:?usage: $0 <kernel-tree>}"
cd "$KDIR"

[ -f mm/memcontrol.c ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

python3 - <<'PY'
import sys

path = "mm/memcontrol.c"
src = open(path).read()

if "report the hierarchical counter instead" in src:
    print("already applied")
    raise SystemExit(0)

old = (
    "#ifdef CONFIG_MEMCG_HEIMDALL\n"
    "\t\tval = memcg_page_state(memcg, MEMCG_RSS);\n"
    "\t\tif (swap)\n"
    "\t\t\tval += memcg_page_state(memcg, MEMCG_SWAP);\n"
    "#else\n"
    "\t\tif (!swap)\n"
    "\t\t\tval = page_counter_read(&memcg->memory);\n"
    "\t\telse\n"
    "\t\t\tval = page_counter_read(&memcg->memsw);\n"
    "#endif"
)
new = (
    "\t\t/*\n"
    "\t\t * CONFIG_MEMCG_HEIMDALL reports only this cgroup's own RSS here,\n"
    "\t\t * which hides the hierarchical total the page counter already\n"
    "\t\t * tracks. The kubelet reads memory.usage_in_bytes for node and\n"
    "\t\t * container memory, so report the hierarchical counter instead.\n"
    "\t\t */\n"
    "\t\tif (!swap)\n"
    "\t\t\tval = page_counter_read(&memcg->memory);\n"
    "\t\telse\n"
    "\t\t\tval = page_counter_read(&memcg->memsw);"
)

if old not in src:
    sys.exit(
        "mem_cgroup_usage: expected CONFIG_MEMCG_HEIMDALL block not found.\n"
        "The tree changed; re-read mm/memcontrol.c before patching."
    )

open(path, "w").write(src.replace(old, new, 1))
print("patched mem_cgroup_usage")
PY

echo "==> result"
sed -n "$(grep -n 'static unsigned long mem_cgroup_usage' mm/memcontrol.c | cut -d: -f1),+24p" mm/memcontrol.c
echo "OK: memory.usage_in_bytes now comes from the hierarchical page counter"
