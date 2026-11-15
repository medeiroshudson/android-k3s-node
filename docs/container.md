# Container: a real Linux userspace on the device's kernel

The node runs inside a [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
container: a privileged, name-spaced Linux system that boots its own `systemd` on the
device's kernel. No emulation, no VM — `kubelet` sees the phone's CPU and RAM.

## Why a container at all

`kubelet` needs glibc, systemd and a normal filesystem layout; Android is bionic with
neither. A chroot is not enough (`systemd` cannot be PID 1 without namespaces), and a VM
is not available: phones expose no `/dev/kvm`, so QEMU would run under TCG at a fraction
of the speed. A Droidspaces container gives a real Debian userspace with native
performance.

## Container settings that matter

| Setting | Value | Why |
|---|---|---|
| `net_mode` | `nat` | own network namespace; needed so `tailscaled` inside owns `tailscale0` |
| `force_cgroupv1` | `1` | with the `cgroups.json` override, `memory` is v1 and kubelet accepts it |
| `privileged` | `full` | kubelet and Docker need to mount and create namespaces |
| `selinux_permissive` | `1` | the container mounts filesystems Android's policy would deny; see the warning below |
| `enable_hw_access` | `1` | exposes `/dev/kmsg`, which k3s reads |
| `memory_limit` | `4294967296` | 4 GiB cap: without it a runaway pod OOMs Android itself |
| `use_sparse_image` | `1` | ext4 inside a sparse file; a directory rootfs gets SELinux labels that corrupt binaries over time |
| `sparse_image_size_gb` | `64` | grows on demand, so the ceiling costs nothing |
| `run_at_boot` | `1` | honoured by the init service in `docs/boot.md` |

`/dev/kmsg` is required by k3s and is not exposed unless hardware access is on.

> **SELinux:** Droidspaces switches the host to permissive when the container requests it.
> That weakens the phone as a phone, and is acceptable here only because the device is
> dedicated to the cluster. If it is your daily driver, drop `selinux_permissive` and add
> the policy rules instead.

## Rootfs

Use a first-party image from the Droidspaces rootfs repository (Debian 13, Ubuntu 24.04
or similar). Two constraints decide the choice:

- **systemd 258 dropped support for kernels older than 5.4.** On a 4.19 kernel use a
  distribution whose systemd is older: Debian 12/13, Ubuntu 22.04/24.04, or a non-systemd
  distro.
- The image must be an **ext4 sparse file**, not a directory: OverlayFS on f2fs (Android's
  `/data`) refuses the directory as a lower layer, and SELinux labels inside a directory
  rootfs corrupt binaries.

`scripts/` in this repo assumes the container is already installed and only manages the
overrides and the boot hook. Install the rootfs with the Droidspaces app or its CLI.

## Docker inside the container

k3s commonly runs with `--docker` (container runtime = Docker) because it is what the
host distributions in this fleet already use. Two settings are mandatory on a 4.19 kernel:

```json
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "2" }
}
```

- **`cgroupfs`** matches `kubelet`; mixing drivers is unsupported. With the cgroups
  override, `memory` lives in v1 and Docker sees it.
- **`local` logging** matters because the container's journal and Docker logs live inside
  a sparse image; `json-file` grows without limit.

### The `cpuset` workaround

Samsung's kernel mounts `cpuset` in a "noprefix" v1 mode, so the file is
`/sys/fs/cgroup/cpuset/cpus` instead of the `cpuset.cpus` Docker expects:

```text
failed to create task ... unable to apply cgroup configuration:
open /sys/fs/cgroup/cpuset/docker/cpuset.cpus: no such file or directory
```

Docker does not use cpuset unless asked, and leaving that hierarchy mounted breaks
container creation. Ship a unit that unmounts it before Docker starts:

```ini
# /etc/systemd/system/fix-cgroup-cpuset.service
[Unit]
Description=Unmount Android noprefix cpuset cgroup v1 for Docker/k3s compatibility
DefaultDependencies=no
Before=docker.service k3s-agent.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if mountpoint -q /sys/fs/cgroup/cpuset && \
  [ ! -e /sys/fs/cgroup/cpuset/cpuset.cpus ]; then umount -l /sys/fs/cgroup/cpuset; fi'

[Install]
WantedBy=multi-user.target
```

`systemctl enable --now fix-cgroup-cpuset.service`. This is what makes
`docker run hello-world` work; without it, every container fails with the error above.

## Minimal k3s agent configuration

```yaml
# /etc/rancher/k3s/config.yaml
node-name: <name>
node-ip: <tailscale ip>
flannel-iface: tailscale0
node-label:
  - "topology.kubernetes.io/zone=home"
  - "node.kubernetes.io/instance-type=mobile"
node-taint:
  - "node-role.kubernetes.io/mobile=true:NoSchedule"
kubelet-arg:
  - "cgroup-driver=cgroupfs"
  - "fail-cgroupv1=false"
docker: true
server: https://<server tailscale ip>:6443
token: <server token>
```

`fail-cgroupv1=false` is needed once `memory` is on v1: kubelet 1.31 refuses cgroup v1
hosts by default. Pin k3s to **1.34 or older** — Kubernetes 1.35 deprecates cgroup v1.
