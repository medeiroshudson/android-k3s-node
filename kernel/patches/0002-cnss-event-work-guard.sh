#!/usr/bin/env bash
# Applied by build.sh, for parity with the kernel verified on hardware. It is inert
# under clang: the window described below only opens in a GCC build, and build.sh
# refuses to produce one.
#
# cnss_probe() calls cnss_set_plat_priv(), which publishes the global plat_env,
# BEFORE cnss_event_work_init() has run alloc_workqueue() and
# INIT_LIST_HEAD(&plat_priv->event_list). A userspace write to wlan_hdd_state in
# that window posts an event onto an uninitialised list:
#
#   list_add corruption. prev is NULL.
#   kernel BUG at lib/list_debug.c:23!
#   __list_add_valid -> cnss_driver_event_post -> cnss_wlan_register_driver
#   -> pld_register_driver -> wlan_hdd_register_driver
#
# The clang build, like the stock kernel, never lands in that window; a GCC 14
# build does, deterministically, about 25 s after boot. The guard below drops the
# event instead of corrupting the list, at the cost of Wi-Fi not coming up, so it
# is a crash fix and not a Wi-Fi fix: prefer building with clang.
#
# Usage: 0002-cnss-event-work-guard.sh <kernel-tree>
set -euo pipefail

KDIR="${1:?usage: $0 <kernel-tree>}"
F="$KDIR/drivers/net/wireless/cnss2/main.c"

[ -f "$F" ] || { echo "file not found: $F" >&2; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8", errors="surrogateescape").read()
anchor = '\tif (!plat_priv)\n\t\treturn -ENODEV;\n\n\tcnss_pr_dbg("Posting event:'
# Check the guard BEFORE the anchor: once the guard is in place the anchor no longer
# exists, so testing the anchor first would fail a re-run instead of reporting it as
# already applied. build.sh applies this patch on every build.
#
# The detector must be the guard itself, not just "if (!plat_priv->event_wq)":
# cnss_event_work_init() contains that same test against the newly allocated
# workqueue, so the short form matches pristine source and the patch would report
# "already applied" on a tree that has nothing.
guard_marker = 'if (!plat_priv->event_wq)\n\t\treturn -EAGAIN;'
if guard_marker in src:
    print("already applied")
    raise SystemExit(0)
if src.count(anchor) != 1:
    sys.exit("anchor not found exactly once - refusing to edit")
guard = (
    '\tif (!plat_priv)\n\t\treturn -ENODEV;\n\n'
    '\t/*\n'
    '\t * plat_env is published before cnss_event_work_init() creates the event\n'
    '\t * workqueue and list; posting in that window corrupts an empty list.\n'
    '\t */\n'
    '\tif (!plat_priv->event_wq)\n\t\treturn -EAGAIN;\n\n'
    '\tcnss_pr_dbg("Posting event:'
)
open(p, "w", encoding="utf-8", errors="surrogateescape").write(src.replace(anchor, guard, 1))
print("OK: cnss event guard inserted")
PY
