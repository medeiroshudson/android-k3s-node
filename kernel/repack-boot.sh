#!/usr/bin/env bash
# Swap the kernel in an existing boot.img, keeping its ramdisk (Magisk), dtb and
# header geometry.
#
#   ./repack-boot.sh boot-stock.img out/arch/arm64/boot/Image.gz boot-new.img
#
# Header values below come from the r8q boot image and must be re-read from your
# own image if you use this on another device (unpack_bootimg prints them all).
set -euo pipefail

BOOT_IN="${1:-boot-stock.img}"
IMAGE_GZ="${2:-out/arch/arm64/boot/Image.gz}"
BOOT_OUT="${3:-boot-k3s-node.img}"

[ -f "$BOOT_IN" ] || { echo "boot image not found: $BOOT_IN" >&2; exit 1; }
[ -f "$IMAGE_GZ" ] || { echo "kernel not found: $IMAGE_GZ" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking $BOOT_IN"
unpack_bootimg --boot_img "$BOOT_IN" --out "$WORK/unpacked"

echo "==> decompressing the kernel"
if file "$IMAGE_GZ" | grep -q gzip; then
    gunzip -c "$IMAGE_GZ" > "$WORK/Image"
else
    cp "$IMAGE_GZ" "$WORK/Image"
fi
ls -l "$WORK/Image"

echo "==> rebuilding $BOOT_OUT"
mkbootimg \
    --kernel "$WORK/Image" \
    --ramdisk "$WORK/unpacked/ramdisk" \
    --dtb "$WORK/unpacked/dtb" \
    --header_version 2 --pagesize 4096 \
    --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
    --dtb_offset 0x1f00000 \
    --os_version 16.0.0 --os_patch_level 2026-11 \
    --cmdline "androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 console=null firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 lpm_levels.sleep_disabled=1 msm_rtb.filter=0x237 printk.devkmsg=on service_locator.enable=1 swiotlb=2048" \
    --output "$BOOT_OUT"

ls -l "$BOOT_OUT"
echo
echo "flash only the boot partition, and keep the stock image for rollback:"
echo "  heimdall flash --BOOT $BOOT_OUT"
