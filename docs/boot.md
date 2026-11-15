# Boot integration: starting the container without touching the phone

The container must come back by itself after a reboot, or the node disappears from the
cluster. On this device the obvious mechanisms do not work, and both failures are worth
knowing before you debug them yourself.

## Why not Magisk's `service.d`

Magisk runs `/data/adb/service.d/*.sh` and module scripts at `late_start service`. On
Magisk 31.1 here, the bundled busybox is broken and Magisk re-extracts it on every boot:

```text
** late_start service mode running
* Running service.d scripts
service.d: exec [k3s-mobile-1.sh]
E : execve /debug_ramdisk/.magisk/busybox/busybox failed with 8: Exec format error
```

```bash
$ file /debug_ramdisk/.magisk/busybox/busybox
/debug_ramdisk/.magisk/busybox/busybox: data
```

Nothing in `service.d` runs, and the same applies to module scripts — which is why
Droidspaces' own boot module never starts the container either (`Logs/boot-module.log`
is never created). Replacing the binary does not stick: Magisk restores its copy at boot.

## What works: an init service

Android's init parses `*.rc` from `/system/etc/init` (and `/vendor/etc/init`) regardless
of Magisk, so a file there is enough:

```text
# /system/etc/init/k3s-mobile.rc
service k3s-mobile-container /system/bin/sh /data/adb/service.d/k3s-mobile-1.sh
    class late_start
    user root
    group root system
    seclabel u:r:magisk:s0
    disabled

on property:sys.boot_completed=1
    start k3s-mobile-container
```

Three details, each learned from a failed boot:

1. **`seclabel u:r:magisk:s0` is mandatory.** Without it init refuses:
   `File /system/bin/sh (labeled "u:object_r:shell_exec:s0") has incorrect label or no
   domain transition from u:r:init:s0 to another SELinux domain`.
2. **No `oneshot`.** With `oneshot`, init sends `SIGKILL` to the service's whole process
   group when the main process exits, taking the Droidspaces monitor with it. `setsid`
   did not save it reliably either.
3. **Therefore the script is a supervisor**, not a one-shot start: it starts the container
   and then re-checks every 60 s. A free watchdog, and init never kills the group.

`android/data/adb/service.d/k3s-mobile-1.sh` is that supervisor. It waits 15 s after
`sys.boot_completed` so Android settles before a 64 GB loop image is mounted.

## Installing it

```bash
make install-hook      # pushes the .rc and the supervisor
```

`install-boot-hook.sh` remounts `/` read-write, copies the `.rc`, restores the read-only
mount and syncs. Nothing else on `/system` is touched.

## Verifying the hook

```bash
adb reboot
adb wait-for-device
# after boot completes:
adb shell su -c 'cat /data/local/Droidspaces/Logs/service-d-k3s-mobile-1.log'
adb shell su -c '/data/local/Droidspaces/bin/droidspaces show'
kubectl get node <name>
```

Expected: the log shows `supervisor up` and `k3s-mobile-1 not running, starting`, the
container is listed, and the node is `Ready` about 90 s after the reboot. `dmesg | grep -c
k3s-mobile-container` should be 2 (started once); more than that means init is restarting
the service, which happens if `oneshot` is present.

## Note on `/system` writes

`make install-hook` and `make apply-override` need `/` writable. On this device `/` is a
plain ext4 `dm-linear` (`dm-0`, no verity) and AVB verification is disabled, so
`mount -o rw,remount /` works. On a device with dm-verity enforcing, you need
`adb disable-verity` + `adb remount` (which require `ro.debuggable=1`) or a rebuilt
`super` image.

Both files are inside `/system`, so a LineageOS OTA removes them — see
`docs/operations.md` for `make after-ota`.
