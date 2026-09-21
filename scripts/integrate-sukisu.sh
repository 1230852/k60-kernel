#!/usr/bin/env bash
# Integrate SukiSU-Ultra into a kernel tree without git.
#
# Replicates the exact three steps of upstream SukiSU-Ultra `kernel/setup.sh`:
#   1. SukiSU-Ultra/kernel/  ->  <kernel>/drivers/kernelsu/
#   2. append `obj-$(CONFIG_KSU) += kernelsu/` to <kernel>/drivers/Makefile
#   3. insert `source "drivers/kernelsu/Kconfig"` before `endmenu` in <kernel>/drivers/Kconfig
#
# Differences from upstream setup.sh that matter:
#   * no `git clone` / `git pull` (the git protocol is unusable on the network this
#     was developed on); it consumes an extracted tarball instead
#   * `kernel/include/uapi` upstream is a SYMLINK to the repo-root `uapi/`. On Windows
#     and in some tarball extractions that becomes an unusable reparse point. This script
#     materialises it as a REAL directory so the build does not depend on symlink handling.
set -euo pipefail

KERNEL_DIR="${1:?usage: integrate-sukisu.sh <kernel-tree> <sukisu-repo-root> <branch>}"
SUKISU_ROOT="${2:?missing sukisu repo root}"
BRANCH="${3:-main}"

SRC="$SUKISU_ROOT/kernel"
DST="$KERNEL_DIR/drivers/kernelsu"

[ -d "$KERNEL_DIR/drivers" ] || { echo "ERROR: $KERNEL_DIR/drivers not found"; exit 1; }
[ -d "$SRC" ]              || { echo "ERROR: $SRC not found"; exit 1; }

echo "==> SukiSU-Ultra branch: $BRANCH"
echo "==> step 1: copy kernel module tree"
rm -rf "$DST"
mkdir -p "$DST"
# Copy everything except the uapi symlink, which we materialise below.
tar -C "$SRC" --exclude='./include/uapi' -cf - . | tar -C "$DST" -xf -
echo "    $(find "$DST" -type f | wc -l) files copied"

echo "==> step 1b: materialise include/uapi as a real directory"
if [ -d "$SUKISU_ROOT/uapi" ]; then
	rm -rf "$DST/include/uapi"
	mkdir -p "$DST/include/uapi"
	cp -a "$SUKISU_ROOT/uapi/." "$DST/include/uapi/"
	echo "    $(find "$DST/include/uapi" -type f | wc -l) uapi headers"
else
	echo "ERROR: $SUKISU_ROOT/uapi missing (needed to replace the include/uapi symlink)"; exit 1
fi

echo "==> step 2: patch drivers/Makefile"
if grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile"; then
	echo "    already present, skipping"
else
	printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
	echo "    appended obj-\$(CONFIG_KSU) += kernelsu/"
fi

echo "==> step 3: patch drivers/Kconfig"
if grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig"; then
	echo "    already present, skipping"
else
	# Insert before the final endmenu only.
	python3 - "$KERNEL_DIR/drivers/Kconfig" <<'PY'
import sys, io
p = sys.argv[1]
with io.open(p, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()
idx = None
for i in range(len(lines) - 1, -1, -1):
    if lines[i].strip() == 'endmenu':
        idx = i
        break
if idx is None:
    sys.stderr.write('ERROR: no endmenu found in drivers/Kconfig\n')
    sys.exit(1)
lines.insert(idx, 'source "drivers/kernelsu/Kconfig"\n')
with io.open(p, 'w', encoding='utf-8', newline='') as f:
    f.writelines(lines)
print('    inserted source "drivers/kernelsu/Kconfig" before endmenu')
PY
fi

echo "==> verify integration"
fail=0
[ -f "$DST/Kconfig" ]        && echo "  ok   drivers/kernelsu/Kconfig"        || { echo "  FAIL Kconfig"; fail=1; }
[ -f "$DST/kpm/kpm.c" ]      && echo "  ok   drivers/kernelsu/kpm/kpm.c (KPM)" || { echo "  FAIL kpm/kpm.c"; fail=1; }
[ -d "$DST/include/uapi" ]   && echo "  ok   drivers/kernelsu/include/uapi"   || { echo "  FAIL include/uapi"; fail=1; }
grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile"      && echo "  ok   drivers/Makefile hook"  || { echo "  FAIL Makefile hook"; fail=1; }
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" && echo "  ok   drivers/Kconfig hook" || { echo "  FAIL Kconfig hook"; fail=1; }
[ "$fail" -eq 0 ] || { echo "ERROR: SukiSU integration verification failed"; exit 1; }

echo "==> SukiSU-Ultra integration complete"
