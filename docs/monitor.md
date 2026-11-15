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

### The cluster card is honest about what it measures

metrics-server cannot scrape every kubelet here (the local node is down and the mobile one
times out), so the only node it answers for is `k3s-master`. That means the cluster
percentage is, in practice, the master's percentage — and the card says so instead of
letting a number pass for cluster-wide:

```text
CLUSTER    CPU 28%   1,1 de 4 núcleos        RAM 74%   8,6 de 11,7 GB
           medido em k3s-master · 1 de 3 nós · 35/53 pods      <- amber when partial
```

The collector emits `measured_nodes` with the names it actually got, capacity is
aggregated over that subset, and the footnote turns amber whenever `nodes_reporting` is
below `nodes_total`. A percentage computed against the capacity of the node that reported
is a true statement about that node; against the whole cluster it would be a false one.

## How it works

Collection lives in a shell script, not in Kotlin. One root call per cycle returns one
JSON object; the app is a renderer.

```text
monitor.sh host        every 2 s    /proc/stat · meminfo · pressure · battery · thermal · df
monitor.sh container   every 5 s    droidspaces --json show · cpuinfo · systemctl is-active
monitor.sh cluster     every 15 s   kubectl get nodes · top nodes · pods
```

Why this way:

- the app never forks per metric, only once per cycle;
- the contract can be checked from `adb` with no build step;
- the collector is reusable by cron, ssh or a future exporter.

Two root shells, one per lane. Sharing a single shell made a section come back empty,
because concurrent writes and reads interleave; but a single lock over one shell also
stalled the 2 s host poll behind a 5 s cluster call, which showed up as a panel updating
every 15 s. The cluster section therefore runs on its own shell behind its own lock.

The collector is installed from the APK's assets behind an install lock, and only when the
content differs from what is on the device. Copying it on every launch raced the pollers:
a section that started mid-copy executed a half-written script and reported a syntax error
at a random line.

### Cost per cycle

Measured on the device with `/proc/uptime`, after batching every section into one pass
per source:

| Section | Before | Now | Why it was slow |
|---|---|---|---|
| host | 2.53 s | 1.15 s | 85 `cat`s, one per thermal zone; four greps over `/proc/meminfo` |
| container | 2.92 s | 1.05 s | `droidspaces --json show` forked once per field (seven times), plus three round trips |
| cluster | 8.31 s | 5.30 s | one round trip per kubectl call; now a single round trip carrying all three |

Forks are the cost on Android, not bytes. The lesson generalises: read a source once and
split the result in the shell, do not call out per field.

Two measurement traps worth keeping in mind when editing the collector:

- `nproc` reports the affinity mask of the calling process, not the CPU count: through
  `su` it answered 6 and 7 on an 8-core phone. Core counts come from
  `grep -c ^processor /proc/cpuinfo`.
- `cpu_permill` is permille of the container's whole capacity, verified by saturating cores:
  one busy loop reports ~127 with 8 cores, three report ~383 (`1000/8 = 125` per core).
  It is not a percentage and not per-core.
- `/system/bin/sh` is mksh, where `|` is alternation inside `${var%%|*}`: the split
  returns an empty string instead of failing loudly. Field separators in the collector
  use `~`, not `|`.

## Install

```bash
make monitor          # builds the APK and pushes the collector
adb install -r monitor/app/build/outputs/apk/debug/app-debug.apk
adb shell cmd package set-home-activity dev.hmedeiros.k3smonitor/.MainActivity
adb shell settings put global stay_on_while_plugged_in 7
adb shell dumpsys deviceidle whitelist +dev.hmedeiros.k3smonitor
adb shell locksettings set-disabled true     # dedicated device: no keyguard
# Magisk toasts "granted superuser" over the panel on every launch; the policy
# is already granted, so the notification is pure noise on a kiosk screen.
adb shell su -c 'magisk --sqlite "UPDATE policies SET notification=0 WHERE uid=10173"'
```

The app installs `monitor.sh` from its own assets on first run, so there is no manual push.

Root is granted by Magisk on first launch. If the panel shows `—` everywhere, the cause is
almost always a missing root grant or a stopped container.

## OLED

The panel is a phone screen left on all day, so the palette is built for an OLED panel:

| Choice | Reason |
|---|---|
| background `#000000` | those pixels are off, not merely dark |
| cards `#0B1013`, tracks `#141D20` | as dark as a surface can be and still read as a card |
| text `#D8E2E4`, labels `#75858C` | least brightness that stays legible; every lit pixel costs power |
| no borders, gaps only | borders light a full perimeter for a distinction tone already makes |

Burn-in is the other half of the problem and is not addressed yet: a static layout on an
OLED panel for months will leave a mark. A slow drift of the whole composition (a few
pixels every few minutes) is the usual remedy and is not implemented.

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
- The first seconds after a reboot show the cluster card as `—` and the pill as
  `aguardando` while the first `kubectl` round trip runs; that is unknown, not NotReady.
- The temperature shown is the hottest thermal zone in the phone (85 zones, one `cat`),
  which during an update is the CPU and at rest is usually the PMIC.
- The panel is landscape-only by design (`sensorLandscape`); a portrait layout is not
  implemented.
