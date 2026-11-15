# Monitor: a home screen for the node

A small Android app that replaces the launcher on a device dedicated to the cluster and
shows what the node is doing: CPU, memory, container usage, disk, temperature, battery,
services and cluster readiness.

The phone boots straight into it, keeps the screen on while charging, and is exempt from
Doze so the panel never freezes.

```text
k3s-mobile-1                             ● Ready        atualizado 2s
container 1m · v1.31.4+k3s1

CPU 5%            MEMÓRIA 48%            CONTAINER 10%
6 núcleos         2,7 de 5,5 GB          423 MB de 4,0 GB
load 3,12

TEMPERATURA 40,9 °C   BATERIA 100%       DISCO 4%
bateria 34,0 °C       full               2,9 de 62,9 GB

SERVIÇOS  k3s-agent ●  docker ●  ssh ●  tailscaled ●
```

## How it works

Collection lives in a shell script, not in Kotlin. One root call per cycle returns one
JSON object; the app is a renderer.

```text
monitor.sh host        every 2 s    /proc/stat · meminfo · pressure · battery · thermal · df
monitor.sh container   every 5 s    droidspaces --json show · systemctl is-active
monitor.sh cluster     every 15 s   kubectl get node / pods
```

Why this way:

- the app never forks per metric, only once per cycle;
- the contract can be checked from `adb` with no build step;
- the collector is reusable by cron, ssh or a future exporter.

The three pollers share one root shell, so `RootShell.collect` holds a `Mutex`: without it
the writes and reads interleave and a section comes back empty (the UI then shows `—`).

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

- `kubectl top` reports `<unknown>` for this node: the metrics-server cannot scrape it.
  The panel therefore reads CPU and RAM from `/proc` and from `droidspaces`, which is the
  accurate local source. Fixing metrics-server is a separate cluster task.
- The first ~60 s after a reboot show the container and cluster cards empty, because the
  container is still booting; the next poll fills them in.
- The panel is landscape-only by design (`sensorLandscape`); a portrait layout is not
  implemented.
