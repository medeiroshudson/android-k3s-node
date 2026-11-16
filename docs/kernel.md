# Kernel: what to enable and how to build it

The device's stock LineageOS kernel has `PID_NS`, `IPC_NS`, `SYSVIPC`, `CGROUP_PIDS`,
`CGROUP_DEVICE`, `DEVTMPFS`, `USER_NS` and `VXLAN` **disabled** — containers cannot start,
and a k3s node cannot form a pod network. `k3s-droidspaces.config` turns them on.

## The fragment

`kernel/k3s-droidspaces.config` is a defconfig fragment for
`arch/arm64/configs/`. It covers three groups:

- **Container runtime:** namespaces (`PID`, `IPC`, `UTS`, `NET`, `USER`), `SYSVIPC`,
  `POSIX_MQUEUE`, `CGROUP_DEVICE`, `CGROUP_PIDS`, `CGROUP_NET_PRIO`, `DEVTMPFS`,
  `OVERLAY_FS`, `SECCOMP_FILTER`.
- **Pod networking:** `VETH`, `BRIDGE`, `BRIDGE_NETFILTER`, `NETFILTER`, `NF_TABLES`,
  `NF_NAT`, `IP_NF_TARGET_MASQUERADE`, `IP_SET` and `VXLAN` (flannel's backend).
- **`CFS_BANDWIDTH` is deliberately absent**, together with `FAIR_GROUP_SCHED`. Enabling
  them on this Samsung tree changes scheduler group behaviour and is not needed: the
  hybrid cgroup layout cannot enforce CPU quotas anyway.

## The toolchain trap that costs hours

In this tree the kernel `Makefile` assigns `CC = $(CROSS_COMPILE)gcc`, which **overrides
`CC` from the environment**. Exporting `CC=clang` therefore builds with GCC while
`.config` still claims `CONFIG_CC_IS_GCC=y`. To build with clang you must pass it on the
command line:

```bash
make O=out CC=clang LD=ld.lld AR=llvm-ar ... Image.gz     # note: after O=out, not exported
```

This matters more than it looks. A **GCC 14** build of this tree boots and then panics at
~25 s inside the Qualcomm WLAN driver:

```text
list_add corruption. prev is NULL.
kernel BUG at lib/list_debug.c:23!
 __list_add_valid
 cnss_driver_event_post
 cnss_wlan_register_driver
 pld_register_driver
 wlan_hdd_register_driver
 wlan_hdd_state_ctrl_param_write
```

`cnss_probe()` publishes `plat_env` **before** `cnss_event_work_init()` creates the event
workqueue and list, so a userspace write to `wlan_hdd_state` inside that window posts an
event onto an uninitialised list. The stock kernel (clang + LTO) never hits the window;
the GCC build's timing does. The clang build of the same `.config` boots clean **with
Wi-Fi working**, which is why this repo builds with clang and treats `patches/0002` as
optional.

## The extern-inline fix

Kernel 4.19 uses the gnu89 inline pattern in a place modern compilers reject:

```text
include/linux/mm.h:2948:20: error: inlining failed in call to 'always_inline'
'need_memory_boosting': function body not available
```

The declaration is `extern inline` in the header and the definition is `inline` in
`mm/vmscan.c`. `patches/0001-extern-inline-need-memory-boosting.sh` turns both into plain
external linkage — the emitted code is unchanged, only the linkage rules are made explicit.

Warnings-as-errors also need relief on a modern clang; pass `KCFLAGS="-Wno-error"` once
rather than patching a dozen vendor headers.

## memory.usage_in_bytes on this kernel

`CONFIG_MEMCG_HEIMDALL` (Samsung) replaces the hierarchical counter inside
`mem_cgroup_usage()`:

```c
#ifdef CONFIG_MEMCG_HEIMDALL
        val = memcg_page_state(memcg, MEMCG_RSS);
#else
        val = page_counter_read(&memcg->memory);
#endif
```

So `memory.usage_in_bytes` reports only the cgroup's own RSS, while the page counter keeps
the real hierarchical total. On the container root the two disagreed by a factor of thirty:
`usage_in_bytes` read 26 MB while `max_usage_in_bytes` — the counter's watermark — had
peaked at 900 MB.

The kubelet reads `usage_in_bytes` for node memory and for every container, so it reported
`workingSetBytes: 0` for the node and metrics-server had nothing valid to publish:
`kubectl top nodes` showed `<unknown>` for `k3s-mobile-1`.

`patches/0003-memcg-usage-hierarchical.sh` keeps the HEIMDALL block everywhere else
(`memory.force_shrink`, the reclaim loop cap) and uses the page counter only in
`mem_cgroup_usage()`. Measured after flashing:

| | before | after |
|---|---|---|
| `node.memory.usageBytes` | 2 MB | 494 MB |
| `node.memory.workingSetBytes` | 0 | 182 MB |
| `kubectl top nodes` | `<unknown>` | `209m 2% 256Mi 6%` |

Container-level metrics stay broken: the kubelet still cannot read the cgroup of each
container (`container_memory_working_set_bytes` arrives as 0), so pod metrics for this node
are absent. That is a different defect from the one this patch fixes.

## Build

```bash
git clone --depth=1 -b lineage-23.2 \
  https://github.com/LineageOS/android_kernel_samsung_sm8250.git
cd android_kernel_samsung_sm8250

../android-k3s-node/kernel/patches/0001-extern-inline-need-memory-boosting.sh .
../android-k3s-node/kernel/patches/0003-memcg-usage-hierarchical.sh .
cp ../android-k3s-node/kernel/k3s-droidspaces.config arch/arm64/configs/

export ARCH=arm64
MAKE_ARGS="CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
OBJDUMP=llvm-objdump STRIP=llvm-strip CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=clang HOSTCXX=clang++"

make O=out $MAKE_ARGS vendor/kona-perf_defconfig
scripts/kconfig/merge_config.sh -O out out/.config \
  arch/arm64/configs/vendor/samsung/kona-sec-common.config \
  arch/arm64/configs/vendor/samsung/r8q.config \
  arch/arm64/configs/k3s-droidspaces.config
make O=out $MAKE_ARGS olddefconfig
KCFLAGS="-Wno-error" make O=out $MAKE_ARGS -j"$(nproc)" Image.gz
```

Verify before flashing: `grep -E '^CONFIG_(PID_NS|IPC_NS|USER_NS|VXLAN|DEVTMPFS)=y' out/.config`
must list all of them, and `out/arch/arm64/boot/Image.gz` must exist.

## Repack boot.img

The stock `boot.img` is header v2, page size 4096, uncompressed `Image`, with the Magisk
ramdisk. `kernel/repack-boot.sh` unpacks the current image, swaps the kernel for yours and
rebuilds it with the **exact** header geometry, so the ramdisk (and therefore root) is
preserved.

Keep a copy of the stock image as your rollback and flash only the `boot` partition.

## Devices this was verified on

`r8q` / SM-G780G, LineageOS 23.2, kernel 4.19.325-cip136-st20, Magisk 31.1. The commit
the running build was derived from is `50cffe6c51d9` — the same one the installed nightly
reports, which keeps the diff to the kernel `.config` only.
