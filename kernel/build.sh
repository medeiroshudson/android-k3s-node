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
