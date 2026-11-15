# Monitor: a home screen for the node

A small Android app that replaces the launcher on a device dedicated to the cluster and
shows what the node is doing: CPU, memory, container usage, disk, temperature, battery,
services and cluster readiness.

The phone boots straight into it, keeps the screen on while charging, and is exempt from
Doze so the panel never freezes.

Three cards, same shape, different scope — the eye compares at the same place in each:

```text
k3s-mobile-1                                  ● Ready      atualizado 1s
v1.31.4+k3s1 · 2/3 nós Ready
┌───────────────────────┬───────────────────────┬───────────────────────┐
│ HOST                  │ NODE                  │ CLUSTER               │
│                       │                       │                       │
│ CPU              4%   │ CPU              0%   │ CPU             28%   │
│ ▓░░░░░░░░░░░░░░░░░░   │ ░░░░░░░░░░░░░░░░░░░   │ ▓▓▓▓▓▓░░░░░░░░░░░░░   │
│ 8 núcleos · load 3,59 │ 0,0 de 8 núcleos      │ 1,1 de 4 núcleos      │
│                       │                       │                       │
│ RAM             50%   │ RAM             10%   │ RAM             56%   │
│ ▓▓▓▓▓▓▓▓▓░░░░░░░░░░   │ ▓▓░░░░░░░░░░░░░░░░░   │ ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░   │
│ 2,8 GB de 5,5 GB      │ 432 MB de 4,0 GB      │ 6,5 GB de 11,7 GB     │
│                       │                       │                       │
│ swap 107 MB de 2,0 GB │ container ativo há 17m│ 1 de 3 nós medidos · 34/53 pods │
└───────────────────────┴───────────────────────┴───────────────────────┘
┌───────────────────────┬───────────────────────┬───────────────────────┐
│ TEMPERATURA  41,5 °C  │ BATERIA  100%         │ DISCO  4%             │
│ bateria 35,1 °C       │ cheia                 │ 2,9 GB de 62,9 GB     │
└───────────────────────┴───────────────────────┴───────────────────────┘
SERVIÇOS  k3s-agent ●  docker ●  ssh ●  tailscaled ●
```

### What each number means

| Card | CPU | Memory | Source |
|---|---|---|---|
| HOST | `/proc/stat` delta over 200 ms, all 8 cores | `MemTotal - MemAvailable` | kernel |
| NODE | `cpu_permill` from the container runtime, permille of the **whole** container | `ram_used_kb` of `ram_limit_kb` | `droidspaces --json show` |
| CLUSTER | `kubectl top nodes` against capacity of the nodes that answer | same | metrics-server + `kubectl get nodes` |

`nodes_reporting` is not decoration: metrics-server here only scrapes some kubelets
(the local and mobile ones time out), so the cluster percentage is computed against the
capacity of the nodes that actually report, and the card says how many of the total that
is. With one of three nodes reporting, cluster CPU is `1.1 of 4` cores, not `1.1 of 20`.
The footnote turns amber whenever the coverage is partial, so the number is never read as
the whole cluster when it is not.

## How it works

Collection lives in a shell script, not in Kotlin. One root call per cycle returns one
JSON object; the app is a renderer.

```text
monitor.sh host        every 2 s    /proc/stat · meminfo · pressure · battery · thermal · df
monitor.sh container   every 5 s    droidspaces --json show · nproc · systemctl is-active
monitor.sh cluster     every 15 s   kubectl get nodes · top nodes · pods
```

Why this way:

- the app never forks per metric, only once per cycle;
- the contract can be checked from `adb` with no build step;
- the collector is reusable by cron, ssh or a future exporter.

The three pollers share one root shell, so `RootShell.collect` holds a `Mutex`: without it
the writes and reads interleave and a section comes back empty (the UI then shows `—`).

Two measurement traps worth keeping in mind when editing the collector:

- `nproc` reports the affinity mask of the calling process, not the CPU count: through
  `su` it answered 6 and 7 on an 8-core phone. Core counts come from
  `grep -c ^processor /proc/cpuinfo`.
- `cpu_permill` is permille of the container's whole capacity, verified by saturating cores:
  one busy loop reports ~127 with 8 cores, three report ~383 (`1000/8 = 125` per core).
  It is not a percentage and not per-core.

## Install

```bash
make monitor          # builds the APK and pushes the collector
adb install -r monitor/app/build/outputs/apk/debug/app-debug.apk
adb shell cmd package set-home-activity dev.hmedeiros.k3smonitor/.MainActivity
adb shell settings put global stay_on_while_plugged_in 7
adb shell dumpsys deviceidle whitelist +dev.hmedeiros.k3smonitor
adb shell locksettings set-disabled true     # dedicated device: no keyguard
```

The app installs `monitor.sh` from its own assets on first run, so there is no manual push.

Root is granted by Magisk on first launch. If the panel shows `—` everywhere, the cause is
almost always a missing root grant or a stopped container.

## Build

Needs JDK 17 and the Android SDK (platform 36, build-tools 36):

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
cd monitor && ./gradlew assembleDebug
```

`local.properties` with `sdk.dir` is generated locally and is not committed.

## Reverting

```bash
adb shell cmd package set-home-activity com.android.launcher3/.uioverrides.QuickstepLauncher
adb shell settings put global stay_on_while_plugged_in 0
adb shell locksettings set-disabled false
adb uninstall dev.hmedeiros.k3smonitor
```

## Known limits

- `kubectl top` reports `<unknown>` for this node: the metrics-server cannot scrape it
  (`context deadline exceeded` toward `100.92.108.16:10250`). The HOST and NODE cards do
  not depend on it — they read the kernel and the runtime — and the CLUSTER card shows the
  coverage it actually has. Fixing metrics-server is a separate cluster task.
- The first ~60 s after a reboot show the container and cluster cards empty, because the
  container is still booting; the next poll fills them in.
- The panel is landscape-only by design (`sensorLandscape`); a portrait layout is not
  implemented.
