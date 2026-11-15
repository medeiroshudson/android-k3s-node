#!/usr/bin/env bash
# Kernel 4.19 + a modern compiler (clang 19 / GCC 13+) reject the gnu89 inline
# pattern used by Samsung's need_memory_boosting:
#
#   include/linux/mm.h:2948:20: error: inlining failed in call to 'always_inline'
#   'need_memory_boosting': function body not available
#
# The header declares it `extern inline` and mm/vmscan.c defines it `inline`.
# Turning both into plain external linkage keeps the emitted code identical and
# removes the contradiction.
#
# Usage: 0001-extern-inline-need-memory-boosting.sh <kernel-tree>
set -euo pipefail

KDIR="${1:?usage: $0 <kernel-tree>}"
cd "$KDIR"

[ -f include/linux/mm.h ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

sed -i 's/^extern inline bool need_memory_boosting/bool need_memory_boosting/' include/linux/mm.h
sed -i 's/^inline bool need_memory_boosting/bool need_memory_boosting/' mm/vmscan.c

grep -n '^bool need_memory_boosting' include/linux/mm.h mm/vmscan.c
echo "OK: need_memory_boosting now has external linkage"
