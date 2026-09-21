#!/usr/bin/env bash
# Package the built kernel into a flashable AnyKernel3 zip for mondrian (Redmi K60).
set -euo pipefail

REPO_ROOT="$(cd "${1:-$(pwd)}" && pwd)"
cd "$REPO_ROOT"

ARCH=arm64
OUT="${OUT:-$REPO_ROOT/out}"
WORK="${WORK:-$REPO_ROOT/out/packaging}"
AK3_URL="${AK3_URL:-https://codeload.github.com/osm0sis/AnyKernel3/tar.gz/refs/heads/master}"
DEVICE_NAME="${DEVICE_NAME:-mondrian}"
ZIP_NAME="${ZIP_NAME:-K60-mondrian-SukiSU-KPM}"

IMAGE="$OUT/arch/$ARCH/boot/Image.gz"
[ -f "$IMAGE" ] || IMAGE="$OUT/arch/$ARCH/boot/Image"
[ -f "$IMAGE" ] || { echo "ERROR: no kernel image under $OUT/arch/$ARCH/boot/"; exit 1; }

echo "==> preparing AnyKernel3"
rm -rf "$WORK"; mkdir -p "$WORK"
if [ -d "$REPO_ROOT/third_party/AnyKernel3" ]; then
	cp -a "$REPO_ROOT/third_party/AnyKernel3/." "$WORK/"
else
	curl -fsSL "$AK3_URL" -o "$WORK/ak3.tar.gz"
	tar -xzf "$WORK/ak3.tar.gz" -C "$WORK" --strip-components=1
	rm -f "$WORK/ak3.tar.gz"
fi
rm -rf "$WORK/.git" "$WORK/README.md" "$WORK/module" 2>/dev/null || true
[ -f "$WORK/tools/ak3-core.sh" ] || { echo "ERROR: AnyKernel3 layout unexpected (tools/ak3-core.sh missing)"; ls -la "$WORK"; exit 1; }

echo "==> staging image: $(basename "$IMAGE")"
cp -f "$IMAGE" "$WORK/Image.gz"

echo "==> staging dtb(s)"
# SAFETY: only device trees that actually belong to this device are packaged, and only
# when explicitly requested with WITH_DTB=1.
#
# Why this is gated: the MiCode `mondrian-s-oss` tree does NOT contain vendor device
# trees. `arch/arm64/boot/dts/Makefile` includes the `vendor` subdirectory only when
# arch/arm64/boot/dts/vendor/Makefile exists, and it does not. So `make dtbs` silently
# succeeds while emitting ~760 UPSTREAM REFERENCE BOARD trees (apq8016, msm8916,
# msm8996, ...) that have nothing to do with the Redmi K60.
#
# Flashing a wrong DTB can brick the device. Therefore:
#   * default: no dtb/ directory at all -> we replace only the kernel inside `boot` and
#     rely on the stock vendor_boot/dtbo device tree (the normal GKI arrangement)
#   * WITH_DTB=1: package only .dtb files whose name matches the device/platform
WITH_DTB="${WITH_DTB:-0}"
mkdir -p "$WORK/dtb"
DTB_COUNT=0
SKIPPED=0
if [ "$WITH_DTB" = "1" ]; then
	while IFS= read -r f; do
		base="$(basename "$f")"
		if printf '%s' "$base" | grep -qiE "${DEVICE_NAME}|waipio|sm8450|sm8475"; then
			cp -f "$f" "$WORK/dtb/"
			DTB_COUNT=$((DTB_COUNT + 1))
		else
			SKIPPED=$((SKIPPED + 1))
		fi
	done < <(find "$OUT/arch/$ARCH/boot/dts" -name '*.dtb' 2>/dev/null | head -n 2000)
	echo "    packaged $DTB_COUNT device-specific dtb, skipped $SKIPPED unrelated dtb"
	if [ "$DTB_COUNT" -eq 0 ]; then
		echo "    NOTE: no device-specific dtb found; the tree has no vendor device trees."
		echo "          Falling back to kernel-only packaging (stock vendor_boot/dtbo keeps the DTB)."
	fi
else
	echo "    skipped (default). Stock vendor_boot/dtbo supplies the device tree."
	echo "    set WITH_DTB=1 only if you have verified device-specific device trees."
fi
if [ "$DTB_COUNT" -eq 0 ]; then rm -rf "$WORK/dtb"; fi

echo "==> writing anykernel.sh"
cat > "$WORK/anykernel.sh" <<EOF
# AnyKernel3 Ramdisk Mod Script
# Redmi K60 ($DEVICE_NAME / SM8475) - SukiSU-Ultra + KPM kernel

properties() { '
kernel.string=Redmi K60 ($DEVICE_NAME) SukiSU-Ultra + KPM
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=$DEVICE_NAME
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
RAMDISK_PATCHLEVEL=auto;

. tools/ak3-core.sh;

split_boot;
flash_boot;
EOF

echo "==> creating zip"
ZIP="$OUT/$ZIP_NAME.zip"
rm -f "$ZIP"
( cd "$WORK" && zip -r9 "$ZIP" . -x '*.git*' >/dev/null )
ls -lh "$ZIP"
unzip -l "$ZIP" | tail -n 15
echo "==> done: $ZIP"
