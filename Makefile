SHELL := /bin/bash
DEVICE  ?= $(shell adb get-serialno 2>/dev/null)

.PHONY: help apply-override install-hook verify after-ota kernel

help:
	@echo "Targets:"
	@echo "  apply-override   install cgroups.json and the init service (needs an unlocked /system)"
	@echo "  install-hook     install only the boot hook and its supervisor"
	@echo "  verify           check memory cgroup v1, container and node Ready"
	@echo "  after-ota        re-apply everything after a LineageOS OTA and verify"
	@echo "  kernel           build the kernel and repack boot.img (see docs/kernel.md)"
	@echo "  monitor          build the monitor APK and push the collector (docs/monitor.md)"

apply-override:
	./scripts/apply-system-overrides.sh --apply

install-hook:
	./scripts/install-boot-hook.sh

verify:
	./scripts/verify-node.sh

after-ota:
	./scripts/after-ota.sh --apply

kernel:
	cd kernel && ./build.sh && ./repack-boot.sh

monitor:
	export JAVA_HOME=/opt/homebrew/opt/openjdk@17; \
	export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools; \
	cd monitor && ./gradlew assembleDebug --console=plain
	adb push monitor/device/monitor.sh /data/local/tmp/monitor.sh
	adb shell su -c 'mkdir -p /data/local/Droidspaces/monitor && cp /data/local/tmp/monitor.sh /data/local/Droidspaces/monitor/monitor.sh && chmod 755 /data/local/Droidspaces/monitor/monitor.sh'
