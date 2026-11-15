# Operations: verify, re-apply after an OTA, roll back

## Verify the node

```bash
make verify
```

`scripts/verify-node.sh` checks, in order:

| Check | Command | Expected |
|---|---|---|
| `/system` override present | `ls /system/etc/cgroups.json` | exists |
| memory on cgroup v1 | `grep '^memory' /proc/cgroups` | hierarchy id **not** 0 |
| memory absent from v2 root | `cat /sys/fs/cgroup/cgroup.controllers` | does not list `memory` |
| `/dev/memcg` usable | `cat /dev/memcg/memory.limit_in_bytes` | a number |
| container running | `droidspaces show` | lists the container |
| k3s agent active | `systemctl is-active k3s-agent` inside | `active` |
| node Ready | `kubectl get node <name>` | `Ready` |

It exits non-zero on the first failure and prints the file to fix.

## After a LineageOS OTA

An OTA rewrites `/system`, taking `cgroups.json` and the init service with it. The node
will come back `NotReady` and k3s will fail with the `memory` cgroup error.

```bash
make after-ota
```

`scripts/after-ota.sh`:

1. verifies `adb` and root; if Magisk is gone (the OTA replaces `boot.img`), it **stops**
   and prints the manual step — re-patch `boot.img` in the Magisk app; this cannot be
   automated without the OTA's boot image;
2. skips everything when the overrides are already in place and the node is healthy;
3. backs up the current `cgroups.json`, validates the new one **locally** with
   `python3 -m json.tool` (an invalid file means zero cgroups at boot), remounts `/` rw,
   copies, `sync`, remounts ro;
4. reinstalls the init service and the supervisor;
5. reboots and waits for the node to be `Ready`, printing the same checks as `verify`.

Use `--check` to run the detection and the verification without writing anything.

**Why validation happens on the host before writing:** `ReadDescriptors()` fails hard on
malformed JSON, and `SetupCgroupsAction` then has no cgroups at all — no `cpuset`, no
`cpuctl`. The device may still boot, but into a degraded scheduling state that is
painful to diagnose.

## Performance

| Item | Value | Why |
|---|---|---|
| container memory cap | 4 GiB | without it a runaway pod OOMs Android; `kubelet` advertises `capacity/allocatable = 4Gi` |
| rootfs image | 64 GB sparse | `/data` has 101 GB free; growth is on demand |
| journald | `SystemMaxUse=200M`, runtime 64M, 14 days | the journal lives inside the sparse image |
| Docker logging | `json-file`, 10 MB × 2 | unbounded without rotation; `local` breaks `kubectl logs` on k3s+Docker |
| `fstrim.timer` | weekly | returns free blocks to the filesystem; the first run released **21 GiB** |
| `tailscale0` MTU | 1280 | tailscaled's default; avoids fragmentation on the VPS↔phone path |

Resize the image (container stopped):

```bash
truncate -s 64G rootfs.img
e2fsck -fy rootfs.img
resize2fs rootfs.img
# then update sparse_image_size_gb in container.config
```

Watch `cat /proc/pressure/memory` after tightening the cap; `full avg10` climbing above
~5 under idle means Android is short on memory and the cap should go down.

## Cluster pods cannot reach each other (flannel orphaned)

Symptom: a pod on the phone resolves the internet but nothing inside the cluster;
`postgresql.infra.svc.cluster.local` times out and DNS to `10.43.0.10` fails.

Cause: flannel's VXLAN device is created at k3s start and bound to `tailscale0`. If
`tailscaled` restarts afterwards, the interface is recreated and `flannel.1` on the
server is left orphaned:

```bash
ip -o link show flannel.1          # missing on the server
ip route | grep 10.42.             # only its own CIDR via cni0
```

Fix: `systemctl restart k3s` on the server. The API is unavailable for a few seconds;
running pods are not restarted.

## Rollback

| Scope | Steps |
|---|---|
| cgroups override | restore the backup written by `apply-system-overrides.sh` (kept at `/sdcard/cgroups.json.orig`) and reboot |
| boot hook | delete `/system/etc/init/k3s-mobile.rc` and `/data/adb/service.d/k3s-mobile-1.sh` |
| kernel | flash the stock `boot.img` you saved before the first flash (`heimdall flash --BOOT boot-stock.img`) |
| system broken after edits | dirty-flash the same LineageOS nightly via sideload: it rewrites `/system` without wiping data |
| node | `kubectl delete node <name>` and `droidspaces --name=<name> stop` |

## Known device quirks worth remembering

- `modprobe` fails for everything: this kernel has **zero modules**, every controller and
  filesystem is built in. Skip `modprobe` in provisioning or provide a synthetic
  `/lib/modules/$(uname -r)/modules.builtin`.
- `adb root` is refused (`ro.debuggable=0`) and `adb remount` is unavailable; root comes
  from Magisk, so `/system` edits go through `mount -o rw,remount /`.
- Android reserves UIDs ≥ 10000, so workloads that insist on a high UID (some system pods)
  need a lower one.
- Submitting a `wlan_hdd_state` write while `cnss` is still probing panics the kernel on a
  GCC build; see `docs/kernel.md`.
