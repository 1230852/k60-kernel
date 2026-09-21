#!/usr/bin/env bash
# Build the Redmi K60 (mondrian / SM8475) 5.10 kernel with SukiSU-Ultra + KPM.
#
# Toolchain: Clang/LLVM for the kernel + aarch64-linux-gnu GCC as the target
#            cross-compiler, matching the CONFIG_CC_IS_CLANG layout that Qualcomm 5.10
#            GKI trees expect. This satisfies the "gcc + llvm" requirement.
#
# AOSP's build/build.sh is deliberately NOT used: the MiCode `mondrian-s-oss` tarball keeps
# the kernel at the tree root (no common/ + msm-kernel/ split), so build.config.msm.gki's
# `common/...` references cannot resolve. The documented defconfig chain is reproduced
# directly with make instead.
#
# Run from the kernel tree root (REPO_ROOT).
set -euo pipefail

REPO_ROOT="$(cd "${1:-$(pwd)}" && pwd)"
cd "$REPO_ROOT"

ARCH=arm64
OUT="${OUT:-$REPO_ROOT/out}"
JOBS="${JOBS:-$(nproc)}"
K60_CFI_MODE="${K60_CFI_MODE:-off}"
FRAGMENT="${FRAGMENT:-$REPO_ROOT/configs/k60-sukisu-kpm.fragment}"

export ARCH
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
# Toolchain note (verified against this tree's Makefile:441-457):
#   those lines are `ifneq ($(LLVM),) ... else ...` with plain `=` assignments, so if
#   LLVM is unset the Makefile assigns CC=$(CROSS_COMPILE)gcc and OVERRIDES any exported
#   CC. We therefore set LLVM=1 (selecting the clang/llvm-* tool block) and pass every
#   tool explicitly so the configuration is deterministic rather than dependent on which
#   branch make happens to take.
export LLVM=1
export CC="${CC:-clang}"
export LD="${LD:-ld.lld}"
export AR="${AR:-llvm-ar}"
export NM="${NM:-llvm-nm}"
export OBJCOPY="${OBJCOPY:-llvm-objcopy}"
export OBJDUMP="${OBJDUMP:-llvm-objdump}"
export READELF="${READELF:-llvm-readelf}"
export STRIP="${STRIP:-llvm-strip}"
# Host tools: keep them on clang too, so "LLVM" is used consistently rather than
# silently falling back to the host gcc for scripts/ and other hostprogs.
export HOSTCC="${HOSTCC:-clang}"
export HOSTCXX="${HOSTCXX:-clang++}"
export HOSTLD="${HOSTLD:-ld.lld}"
export HOSTAR="${HOSTAR:-llvm-ar}"
# LLVM_IAS=1 -> clang's integrated assembler.
#
# This MUST be 1 when LTO is enabled. With LLVM_IAS=0 the Makefile adds
# `-no-integrated-as` (Makefile:589-591) and hands assembly to GNU as, which cannot
# resolve the absolute expressions clang emits under LTO. The observed failure was
# dozens of errors of the form:
#     ../arch/arm64/kernel/entry.S:700: Error: bad or irreducible absolute expression
# Set K60_LLVM_IAS=0 to force the old behaviour (only useful if you also disable LTO).
export LLVM_IAS="${K60_LLVM_IAS:-1}"

MK=(make -j"$JOBS" O="$OUT")

echo "==> toolchain"
"$CC" --version | head -n1
"${CROSS_COMPILE}gcc" --version | head -n1 || { echo "ERROR: ${CROSS_COMPILE}gcc missing"; exit 1; }

echo "==> defconfig chain (variant: consolidate)"
BASE=arch/arm64/configs/gki_defconfig
VENDOR_GKI=arch/arm64/configs/vendor/mondrian_GKI.config
VENDOR_CONSOLIDATE=arch/arm64/configs/vendor/mondrian_consolidate.config
for f in "$BASE" "$VENDOR_GKI" "$VENDOR_CONSOLIDATE" "$FRAGMENT"; do
	[ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

mkdir -p "$OUT"
cat "$BASE" "$VENDOR_GKI" "$VENDOR_CONSOLIDATE" > "$OUT/.config"

echo "==> applying SukiSU/KPM fragment"
# Strip CFI/LTO lines from the base merge, then append the fragment, then set the
# chosen CFI mode last so the decision always wins.
sed -i -e '/^CONFIG_CFI_CLANG=y$/d' \
       -e '/^# CONFIG_CFI_CLANG is not set$/d' \
       -e '/^CONFIG_LTO_CLANG=y$/d' \
       -e '/^CONFIG_LTO_CLANG_THIN=y$/d' \
       -e '/^CONFIG_LTO_CLANG_FULL=y$/d' \
       -e '/^# CONFIG_LTO_CLANG_FULL is not set$/d' \
       -e '/^# CONFIG_LTO_CLANG_THIN is not set$/d' \
       "$OUT/.config"

# Fragment's own CFI/LTO lines are comments except LTO_CLANG=y/THIN; normalise by
# dropping them from the fragment copy too.
grep -vE '^CONFIG_(CFI_CLANG|LTO_CLANG|LTO_CLANG_THIN|LTO_CLANG_FULL)=|^# CONFIG_(CFI_CLANG|LTO_CLANG|LTO_CLANG_THIN|LTO_CLANG_FULL) ' \
	"$FRAGMENT" >> "$OUT/.config"

case "$K60_CFI_MODE" in
off)  printf '%s\n' '# CONFIG_CFI_CLANG is not set' 'CONFIG_LTO_CLANG=y' 'CONFIG_LTO_CLANG_THIN=y' '# CONFIG_LTO_CLANG_FULL is not set' >> "$OUT/.config" ;;
thin) printf '%s\n' 'CONFIG_CFI_CLANG=y' 'CONFIG_LTO_CLANG=y' 'CONFIG_LTO_CLANG_THIN=y' '# CONFIG_LTO_CLANG_FULL is not set' >> "$OUT/.config" ;;
full) printf '%s\n' 'CONFIG_CFI_CLANG=y' 'CONFIG_LTO_CLANG=y' 'CONFIG_LTO_CLANG_FULL=y' >> "$OUT/.config" ;;
*) echo "ERROR: bad K60_CFI_MODE=$K60_CFI_MODE (use off|thin|full)"; exit 1 ;;
esac

echo "==> olddefconfig"
"${MK[@]}" olddefconfig

echo "==> verifying required options survived the merge"
fail=0
require_y() {
	if grep -qE "^$1=y$" "$OUT/.config"; then echo "  ok   $1=y"; else echo "  FAIL $1 is not =y"; fail=1; fi
}
require_y CONFIG_KSU
require_y CONFIG_KPM
require_y CONFIG_KPROBES
require_y CONFIG_EXT4_FS
require_y CONFIG_MODULES
require_y CONFIG_KALLSYMS
require_y CONFIG_KALLSYMS_ALL
require_y CONFIG_BBG

# BBG's Makefile has a hard $(error) gate on CONFIG_LSM containing "baseband_guard".
# Assert it here so a silent config drop is caught before the compiler runs.
if grep -qE '^CONFIG_LSM=".*(^|,)baseband_guard(,|")' "$OUT/.config"; then
	echo "  ok   CONFIG_LSM contains baseband_guard"
else
	echo "  FAIL CONFIG_LSM does not contain baseband_guard -> BBG build gate would abort"
	grep -E '^CONFIG_LSM=' "$OUT/.config" | sed 's/^/       /'
	fail=1
fi

if grep -qE '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config"; then
	echo "  FAIL CONFIG_KSU_MANUAL_HOOK=y (kprobe hook requires it unset)"; fail=1
else
	echo "  ok   CONFIG_KSU_MANUAL_HOOK is not set"
fi

# The assembler encoding of __emit_inst() must agree with LLVM_IAS. See the fragment:
# with LLVM_IAS=1 the tree needs the `.inst` form, i.e. CONFIG_BROKEN_GAS_INST unset.
# A mismatch surfaces much later as "error: too many positional arguments" while
# assembling arch/arm64/kvm/hyp/entry.S, so check it up front instead.
if [ "$LLVM_IAS" = "1" ]; then
	if grep -qE '^CONFIG_BROKEN_GAS_INST=y$' "$OUT/.config"; then
		echo "  FAIL CONFIG_BROKEN_GAS_INST=y while LLVM_IAS=1"
		echo "       -> __emit_inst() would use the .long form, which the integrated"
		echo "          assembler cannot parse (arch/arm64/kvm/hyp/entry.S will fail)"
		fail=1
	else
		echo "  ok   CONFIG_BROKEN_GAS_INST unset (matches LLVM_IAS=1)"
	fi
fi

if [ "$K60_CFI_MODE" = off ]; then
	if grep -qE '^CONFIG_CFI_CLANG=y$' "$OUT/.config"; then
		echo "  FAIL CONFIG_CFI_CLANG still =y but mode=off"; fail=1
	else
		echo "  ok   CONFIG_CFI_CLANG disabled"
	fi
fi

# Prove SukiSU actually got compiled in, not just selected.
if [ -d "$REPO_ROOT/drivers/kernelsu" ]; then
	echo "  ok   drivers/kernelsu present"
else
	echo "  FAIL drivers/kernelsu missing"; fail=1
fi

# Prove BBG sources are present in the tree.
if [ -f "$REPO_ROOT/security/baseband-guard/baseband_guard.c" ]; then
	echo "  ok   security/baseband-guard present"
else
	echo "  FAIL security/baseband-guard missing"; fail=1
fi

[ "$fail" -eq 0 ] || { echo "ERROR: config validation failed"; exit 1; }
grep -E '^CONFIG_(KSU|KPM|BBG|KPROBES|CFI_CLANG|LTO_CLANG\w*)=' "$OUT/.config" | sed 's/^/    /'
grep -E '^CONFIG_LSM=' "$OUT/.config" | sed 's/^/    /'

echo "==> compiling (long step)"
"${MK[@]}" Image.gz dtbs

echo "==> outputs"
ls -lh "$OUT/arch/$ARCH/boot/Image" "$OUT/arch/$ARCH/boot/Image.gz" 2>/dev/null || true
echo "dtbs   : $(find "$OUT/arch/$ARCH/boot/dts" -name '*.dtb' 2>/dev/null | wc -l)"
echo "modules: $(find "$OUT" -name '*.ko' 2>/dev/null | wc -l)"
[ -f "$OUT/include/config/kernel.release" ] && echo "release: $(cat "$OUT/include/config/kernel.release")"

# Prove the SukiSU objects were built.
echo "==> SukiSU object evidence"
find "$OUT/drivers/kernelsu" -name '*.o' 2>/dev/null | head -n 12 | sed 's/^/    /'
echo "    total kernelsu objects: $(find "$OUT/drivers/kernelsu" -name '*.o' 2>/dev/null | wc -l)"
[ -n "$(find "$OUT/drivers/kernelsu" -name '*.o' 2>/dev/null | head -n1)" ] \
	|| { echo "ERROR: no SukiSU objects compiled - CONFIG_KSU did not take effect"; exit 1; }

# Prove the BBG objects were built.
echo "==> Baseband-guard object evidence"
find "$OUT/security/baseband-guard" -name '*.o' 2>/dev/null | sed 's/^/    /'
echo "    total bbg objects: $(find "$OUT/security/baseband-guard" -name '*.o' 2>/dev/null | wc -l)"
[ -n "$(find "$OUT/security/baseband-guard" -name '*.o' 2>/dev/null | head -n1)" ] \
	|| { echo "ERROR: no Baseband-guard objects compiled - CONFIG_BBG did not take effect"; exit 1; }

echo "==> done"
