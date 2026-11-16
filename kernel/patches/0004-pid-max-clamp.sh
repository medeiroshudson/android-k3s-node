#!/usr/bin/env bash
# Cap the kernel-global pid_max at 65535.
#
# bionic refuses to start any 32-bit process once the running pid exceeds 65535
# ("32-bit pthread_mutex_t only supports pids <= 65535"), because pthread_mutex_t
# stores the TID in 16 bits. On 4.19 pid_max is a single global int in
# kernel/pid.c, shared by every pid namespace, so a writer inside the Droidspaces
# container changes it for Android too: Debian's systemd raises it to
# PID_MAX_LIMIT (4194304) at startup, which silently kills every armeabi-v7a app
# on the device -- no log line, no crash, just "start timeout" from
# ActivityManager and a process that never runs.
#
# The sysctl validates writes against pid_max_max, so lowering that ceiling makes
# the container's write fail with EINVAL and leaves the boot value (32768, or
# PIDS_PER_CPU_DEFAULT * cpus if that is higher) untouched.
#
# Consequence, on purpose: no pid namespace can exceed 65535 pids. A phone-sized
# k3s node runs far below that. If a future node needs more, the fix is to
# backport per-namespace pid_max (5.x), not to raise this ceiling.
#
# Usage: 0004-pid-max-clamp.sh <kernel-tree>
set -euo pipefail

KDIR="${1:?usage: $0 <kernel-tree>}"
cd "$KDIR"

[ -f kernel/pid.c ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

python3 - <<'PY'
path = "kernel/pid.c"
src = open(path).read()

if "PID_MAX_COMPAT_CLAMP" in src:
    print("already applied")
    raise SystemExit(0)

old = "int pid_max_max = PID_MAX_LIMIT;"
new = (
    "/* PID_MAX_COMPAT_CLAMP: 32-bit bionic can only handle pids <= 65535.\n"
    " * A container's systemd raises the global pid_max to PID_MAX_LIMIT,\n"
    " * which breaks every 32-bit process on Android. Cap the ceiling so that\n"
    " * write is rejected instead of silently breaking userspace.\n"
    " */\n"
    "int pid_max_max = 65535;"
)

if old not in src:
    raise SystemExit("pid_max_max definition not found in kernel/pid.c")

open(path, "w").write(src.replace(old, new, 1))
print("patched kernel/pid.c")
PY
