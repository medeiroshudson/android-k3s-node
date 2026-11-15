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
