# Why k3s cannot start on Android 16 (and what actually fixes it)

## The split is AOSP, not the vendor

`system/core/libprocessgroup/profiles/cgroups.json` defines which controllers live in
cgroup v1 and which in v2. Compare two tags:

| AOSP tag | v1 controllers | v2 controllers |
|---|---|---|
| `android-15.0.0_r1` | blkio, cpu, cpuset, **memory** | freezer |
| `android-16.0.0_r1` | blkio, cpu, cpuset | freezer, **memory** |

The move came from commit `5fa48a84b5` ("libprocessgroup: memcg default version 1 -> 2",
2024-11-22). `cpu`, `cpuset` and `blkio` stay v1 in every version, because `schedtune`
and the vendor perf stack are built around `/dev/cpuctl`, `/dev/cpuset`, `/dev/stune`.

So on Android 16 the host always presents a **hybrid** layout:

```text
/dev/cpuctl, /dev/cpuset, /dev/blkio, /dev/stune   → cgroup v1
/sys/fs/cgroup (memory)                            → cgroup v2
```

## Why kubelet refuses both modes

`validateSystemRequirements()` in `pkg/kubelet/cm/container_manager_linux.go` early-returns
only when `/sys/fs/cgroup` is cgroup2; otherwise it demands `cpu`, `cpuacct`, `cpuset`
and `memory` among the options of mounts whose fstype is `cgroup`:

| Mode | Failing check |
|---|---|
| v1 (`--cgroup-driver=cgroupfs`) | `Following Cgroup subsystem not mounted: [memory]` — kubelet's validator |
| v2 (`--cgroup-driver=systemd`) | `failed to find cpu cgroup (v2)` — **k3s's own** pre-check in `pkg/cgroups/cgroups_linux.go`, which runs before kubelet |

No flag reaches that validator: `--cgroup-driver` accepts only `cgroupfs`/`systemd`,
`--cgroup-root` changes a path and not a hierarchy, and `--fail-cgroupv1=false` only
lifts the deprecation gate.

## Dead ends, with the reason

| Approach | Why it fails |
|---|---|
| `cgroup_no_v1=all` in the kernel cmdline | kubelet passes, Android loses `/dev/cpuctl`, `/dev/cpuset`, `/dev/blkio` and `schedtune`: no scheduler policy, no top-app boosting, vendor perf/thermal writes start failing. No report of a usable system in this mode |
| Patch kubelet + k3s to tolerate a missing `memory` cgroup | needs forks of `k3s-io/kubernetes` **and** k3s; and pods with `resources.limits.memory` still fail at the runtime (`cannot set memory limit: container could not join or create cgroup`), because limits are applied by runc, not by kubelet |
| Mount a v1 `memory` hierarchy at runtime | `rebind_subsystems()` returns `-EBUSY` once Android has activated `memory` in the v2 root |
| Keep `memory` in both hierarchies | a controller can belong to exactly one hierarchy (`cgroups(7)`) |
| Bind-mount the v2 subtree at `/sys/fs/cgroup/memory` | the validator requires fstype `cgroup`; and the v1 code paths write `memory.limit_in_bytes`, which does not exist in v2 |

## The fix: put `memory` back on v1

Commit `92ca277fb7` (T.J. Mercier, 2025-03-20) states it directly:

> "Vendor overrides to alternate MaxActivationDepths are supported in Android 16.
> **Overrides to memcg v1 are also supported in Android 16.** In Android 17 these
> overrides are not likely to be supported."

Copying the AOSP default and moving the `memory` entry from `Cgroups2.Controllers`
into `Cgroups` is therefore a **supported configuration**, not a hack:

```json
"Cgroups": [ ..., { "Controller": "memory", "Path": "/dev/memcg", "Mode": "0700", "Optional": true } ],
"Cgroups2": { ..., "Controllers": [ { "Controller": "freezer", "Path": "." } ] }
```

Two properties make this safe:

1. **First mount wins.** `CgroupSetup()` walks the descriptor list and mounts memory v1
   before anything could activate it in v2, so Android runs the legacy memcg path the
   same way it did on Android 11–15.
2. **`Optional: true`.** If the kernel disagrees, the failure is a warning
   (`Activation of cgroup controller ... failed`) and boot continues.

## Which file to edit

`libprocessgroup` merges descriptors by controller name, last one winning, in this order:

1. `/system/etc/cgroups.json`
2. `/system/etc/task_profiles/cgroups_<ro.product.first_api_level>.json` (only if present)
3. `/vendor/etc/cgroups.json` (vendor wins)

Check what exists before writing:

```bash
adb shell su -c 'ls -l /system/etc/cgroups.json /vendor/etc/cgroups.json /system/etc/task_profiles/'
adb shell getprop ro.product.first_api_level
```

If `/vendor/etc/cgroups.json` exists, edit **that** file instead; otherwise
`/system/etc/cgroups.json`, as this repo does.

## What you give up

`memory` on v1 means no per-app memcg from v2: no `memory.peak`, no v2 memory PSI
throttling, and a coarser LMKD. On a 4.19 kernel that is a small regression, not a
broken system: PSI landed in 4.20, so this kernel already runs LMKD's pre-PSI fallback.
Validate after applying — `cat /proc/pressure/memory` should stay near zero under idle
load and Android must not kill the container's processes.
