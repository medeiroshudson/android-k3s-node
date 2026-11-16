#!/usr/bin/env bash
# Build Image.gz for a LineageOS sm8250 kernel tree with container support.
#
#   ./build.sh /path/to/android_kernel_samsung_sm8250
#
# Why every option goes on the make command line instead of `export`: this
# tree's Makefile assigns `CC = $(CROSS_COMPILE)gcc`, which overrides the
# environment. Exporting CC=clang silently builds with GCC, and the GCC build of
# this tree panics in the WLAN driver about 25 s after boot (docs/kernel.md).
set -euo pipefail

KDIR="${1:-${KDIR:-$HOME/android_kernel_samsung_sm8250}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

cd "$KDIR"
[ -f Makefile ] && [ -d arch/arm64 ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

echo "==> applying patches"
"$HERE/patches/0001-extern-inline-need-memory-boosting.sh" .
"$HERE/patches/0002-cnss-event-work-guard.sh" .
"$HERE/patches/0003-memcg-usage-hierarchical.sh" .
"$HERE/patches/0004-pid-max-clamp.sh" .
# 0002 is inert under clang (the race only opens in a GCC build) but it is applied
# for parity with the kernel that is verified on hardware. The compiler assertion
# below is what keeps a GCC build from ever being produced here.

echo "==> installing the defconfig fragment"
cp "$HERE/k3s-droidspaces.config" arch/arm64/configs/

export ARCH=arm64
export KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=buildhost
MAKE_ARGS=(
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-
    HOSTCC=clang HOSTCXX=clang++
)

echo "==> defconfig"
make O=out "${MAKE_ARGS[@]}" vendor/kona-perf_defconfig
scripts/kconfig/merge_config.sh -O out out/.config \
    arch/arm64/configs/vendor/samsung/kona-sec-common.config \
    arch/arm64/configs/vendor/samsung/r8q.config \
    arch/arm64/configs/k3s-droidspaces.config
make O=out "${MAKE_ARGS[@]}" olddefconfig

echo "==> checking the toolchain"
# This tree's Makefile assigns CC = $(CROSS_COMPILE)gcc, which overrides the
# environment: exporting CC=clang is enough to silently build with GCC and hit
# the cnss list corruption ~25 s after boot. Assert the config, not the intent.
if ! grep -q "^CONFIG_CC_IS_CLANG=y" out/.config; then
    echo "  kernel would be built with $(grep -m1 '^CONFIG_CC_IS_' out/.config || echo 'an unknown compiler')" >&2
    echo "  refusing: GCC builds net this tree a cnss panic (see docs/kernel.md)" >&2
    echo "  if you really need GCC, apply patches/0002-cnss-event-work-guard.sh and accept no Wi-Fi" >&2
    exit 1
fi
echo "  clang confirmed (CONFIG_CC_IS_CLANG=y)"

# The verified kernel has FAIR_GROUP_SCHED off (stock Samsung config has it off too).
# Turning it on brings cpu.cfs_quota_us into the v1 cpu hierarchy, which changes the
# layout the container and the kubelet already depend on. Refuse the drift instead of
# shipping a kernel nobody validated.
if grep -q "^CONFIG_FAIR_GROUP_SCHED=y" out/.config; then
    echo "  FAIR_GROUP_SCHED is on: this is not the validated configuration" >&2
    echo "  see docs/kernel.md (CPU limits) and docs/why-cgroups.md" >&2
    exit 1
fi
echo "  FAIR_GROUP_SCHED off, as verified"

echo "==> checking that the container options survived the merge"
missing=0
for opt in PID_NS IPC_NS USER_NS VXLAN DEVTMPFS CGROUP_PIDS CGROUP_DEVICE NF_TABLES; do
    if ! grep -q "^CONFIG_${opt}=y" out/.config; then
        echo "  missing: CONFIG_${opt}=y" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "defconfig merge did not produce a k3s-capable kernel" >&2; exit 1; }

echo "==> building (jobs: $JOBS)"
KCFLAGS="-Wno-error" make O=out "${MAKE_ARGS[@]}" -j"$JOBS" Image.gz

ls -l out/arch/arm64/boot/Image.gz
echo
echo "next: ./repack-boot.sh <boot.img> (see docs/kernel.md)"
