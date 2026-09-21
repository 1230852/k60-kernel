#!/usr/bin/env bash
# Pre-flight check: does this kernel tree contain the device trees for the target device?
#
# Why this exists: the MiCode `mondrian-s-oss` drop does not ship vendor device trees.
# `arch/arm64/boot/dts/Makefile` pulls in the `vendor` subdirectory only when
# `arch/arm64/boot/dts/vendor/Makefile` exists -- and it does not. So `make dtbs`
# succeeds while producing nothing for this device, which is exactly the kind of
# silent gap that would otherwise surface only after flashing.
#
# This script does NOT fail the build. It reports the situation loudly and records it,
# because a kernel-only replacement is still a legitimate artifact (GKI devices take
# their device tree from vendor_boot/dtbo).
set -euo pipefail

REPO_ROOT="$(cd "${1:-$(pwd)}" && pwd)"
DEVICE_NAME="${DEVICE_NAME:-mondrian}"

echo "==> device tree pre-flight"
echo "    tree  : $REPO_ROOT"
echo "    device: $DEVICE_NAME"

fail_soft=0

# 1. vendor dts directory
if [ -f "$REPO_ROOT/arch/arm64/boot/dts/vendor/Makefile" ]; then
	echo "  ok   arch/arm64/boot/dts/vendor/Makefile exists"
else
	echo "  WARN arch/arm64/boot/dts/vendor/ is ABSENT"
	echo "       -> arch/arm64/boot/dts/Makefile will silently skip all vendor device trees"
	fail_soft=1
fi

# 2. any device tree naming this device or its platform
PLAT_HITS=$(find "$REPO_ROOT/arch/arm64/boot/dts" -type f \( -name '*.dts' -o -name '*.dtsi' \) \
	2>/dev/null | grep -icE "${DEVICE_NAME}|waipio|sm8450|sm8475" || true)
echo "    device/platform-named dts files: $PLAT_HITS"
if [ "$PLAT_HITS" -eq 0 ]; then
	echo "  WARN no device tree references $DEVICE_NAME / waipio / sm8450 / sm8475"
	fail_soft=1
fi

# 3. platform base dtsi that a Qualcomm 5.10 vendor tree always has
for f in waipio.dtsi sm8450.dtsi; do
	if [ -f "$REPO_ROOT/arch/arm64/boot/dts/qcom/$f" ]; then
		echo "  ok   arch/arm64/boot/dts/qcom/$f"
	else
		echo "  WARN arch/arm64/boot/dts/qcom/$f missing"
	fi
done

# 4. how much upstream noise `make dtbs` would emit
UPSTREAM=$(find "$REPO_ROOT/arch/arm64/boot/dts" -type f -name '*.dts' 2>/dev/null | wc -l)
echo "    upstream reference .dts in tree: $UPSTREAM (these are NOT for this device)"

echo ""
if [ "$fail_soft" -eq 1 ]; then
	echo "==> RESULT: device trees for $DEVICE_NAME are NOT present in this tree."
	echo ""
	echo "    Consequence for packaging:"
	echo "      * 'make dtbs' will succeed but produce no $DEVICE_NAME device tree."
	echo "      * scripts/package-anykernel3.sh therefore ships NO dtb/ by default."
	echo "      * The kernel replaces only the image inside the 'boot' partition and relies"
	echo "        on the stock vendor_boot/dtbo device tree. This is the normal GKI layout,"
	echo "        but it is NOT verified on hardware."
	echo ""
	echo "    To obtain matching device trees, supply a companion source, e.g. the vendor"
	echo "    devicetree from a ROM project that already builds this device."
else
	echo "==> RESULT: device trees look present for $DEVICE_NAME."
fi
exit 0
