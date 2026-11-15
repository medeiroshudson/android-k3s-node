# android-k3s-node

Turn a rooted Android 16 device into a working **k3s agent node** — the kernel, the
container runtime and the boot integration that make `kubelet` actually start.

Android 16 moved the `memory` cgroup controller to cgroup v2 while `cpu`, `cpuset` and
`blkio` stayed on v1. `kubelet` requires all of them in one hierarchy, so every k3s
install on a modern Android device fails with one of two errors:

```text
system validation failed - Following Cgroup subsystem not mounted: [memory]   # v1 mode
failed to find cpu cgroup (v2)                                                # v2 mode
```

This repo contains the fix that works, end to end, without patching kubelet or losing
Android's scheduler policy: a **`cgroups.json` override that puts `memory` back on
cgroup v1**, which AOSP explicitly supports on Android 16.

## What is here

| Path | What it is |
|---|---|
| `kernel/` | Defconfig fragment (namespaces, cgroups, overlayfs, veth/bridge, VXLAN, nftables), the two source fixes a 4.19 tree needs with modern compilers, and build/repack scripts for `boot.img` |
| `android/` | The `/system/etc/cgroups.json` override, the init service that starts the container at boot, and its supervisor script |
| `scripts/` | `apply-system-overrides.sh`, `install-boot-hook.sh`, `verify-node.sh`, `after-ota.sh` |
| `monitor/` | Android home-screen app that shows node and container utilisation (see `docs/monitor.md`) |
| `docs/` | Why the cgroups split exists (with AOSP commits), kernel build traps, container setup, boot integration, operations and rollback |

## Tested on

| Device | Model | SoC | ROM | Kernel | Runtime |
|---|---|---|---|---|---|
| Galaxy S20 FE 4G (`r8q`) | SM-G780G | Snapdragon 865 (sm8250) | LineageOS 23.2 (Android 16), Magisk 31.1 | 4.19.325-cip136-st20 | [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 7.2.0 + Debian 13 |

The cgroups reasoning applies to any Android 16 device. The kernel fragment and the
`cpuset` workaround are specific to 4.19 Samsung/sm8250 kernels — read `docs/` before
porting, and expect to rebuild your own kernel for a different device.

## How it fits together

```text
boot.img (custom kernel: namespaces, cgroups, overlayfs, VXLAN, nftables)
   └─ Android 16 boots; /system/etc/cgroups.json keeps memory on cgroup v1
        └─ /system/etc/init/k3s-mobile.rc starts a supervisor after sys.boot_completed
             └─ Droidspaces container (Debian 13, systemd, NAT, privileged)
                  ├─ Docker with native.cgroupdriver=cgroupfs
                  └─ k3s agent  →  node Ready, taint node-role.kubernetes.io/mobile
```

## Quick start

Prerequisites: unlocked bootloader, rooted device (Magisk), `adb`, a Linux build host
or VM with the LineageOS kernel tree, and `heimdall` for flashing in download mode.

```bash
# 1. build a kernel with container support and flash it
cd kernel && ./build.sh && ./repack-boot.sh    # see docs/kernel.md for the toolchain trap

# 2. install the cgroups override and the boot hook
make apply-override
make install-hook

# 3. verify: memory must be cgroup v1, the container up, the node Ready
make verify
```

## Warning: an OTA undoes half of this

`/system` is rewritten by every LineageOS update, taking `cgroups.json` and the init
service with it. After each OTA, run:

```bash
make after-ota
```

It re-applies both files, reboots and verifies the node. If the OTA also removed
Magisk, it stops and tells you to re-patch `boot.img` first — that step needs the
Magisk app.

## Credits

- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) — the container runtime
  that runs a real Linux userspace on the device's own kernel.
- [Magisk](https://github.com/topjohnwu/Magisk) — root.
- The AOSP commits that define this problem: `5fa48a84b5` (memory to cgroup v2) and
  `92ca277fb7` (vendor memcg v1 overrides supported in Android 16).

## License

GPL-3.0-or-later. Kernel patches are GPL-2.0-only upstream code and stay compatible.
