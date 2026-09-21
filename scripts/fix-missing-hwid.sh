#!/usr/bin/env bash
# Supply a minimal placeholder for the `hwid` module that Xiaomi did not publish.
#
# WHY THIS IS NEEDED (evidence, not guesswork):
#   The MiCode `mondrian-s-oss` drop references a driver directory `drivers/misc/hwid/`
#   that does not exist in the tarball, in three places:
#     drivers/misc/Kconfig:540  source "drivers/misc/hwid/Kconfig"
#     drivers/misc/Makefile:5   ccflags-y += -I$(srctree)/drivers/misc/hwid/
#     drivers/misc/Makefile:68  obj-y += hwid/
#   The first one aborts configuration outright:
#     drivers/misc/Kconfig:540: can't open file "drivers/misc/hwid/Kconfig"
#     make[2]: *** [../scripts/kconfig/Makefile:71: olddefconfig] Error 1
#   (`hwid` is 1 of the 106 modules in modules.list.msm.mondrian with no source in-tree.)
#
# WHY A PLACEHOLDER IS SAFE HERE (verified against the tree):
#   * `drivers/misc/gpio-testing-mode.c` is the only file that includes "hwid.h", and it
#     compiles `CONFIG_GPIO_TESTING_MODE=y`. A full-tree search for hwid/HWID/mi_hwid/
#     get_hwid/hwid_bitmap in that file matches EXACTLY ONE line - the #include itself.
#     It uses no symbol from the header, so an empty header is behaviour-preserving.
#   * The `hwid_bitmap` references in the various `qmi.c` files come from their own
#     `main.h`/`qmi.h` structs, not from hwid.h (those directories have no hwid.h and do
#     not rely on the -I added by drivers/misc/Makefile).
#   * `obj-y += hwid/` needs *some* Makefile in the directory or kbuild aborts with
#     "No rule to make target". An empty Makefile contributes no objects.
#
# This does NOT recreate the Xiaomi hardware-id feature. It only unbreaks the build.
# See the note printed at the end for what is still missing.
set -euo pipefail

KERNEL_DIR="${1:?usage: fix-missing-hwid.sh <kernel-tree>}"
HWID_DIR="$KERNEL_DIR/drivers/misc/hwid"

[ -d "$KERNEL_DIR/drivers/misc" ] || { echo "ERROR: $KERNEL_DIR/drivers/misc not found"; exit 1; }

if [ -d "$HWID_DIR" ] && [ -f "$HWID_DIR/Kconfig" ]; then
	echo "==> drivers/misc/hwid already present, nothing to do"
	exit 0
fi

echo "==> creating placeholder for unpublished 'hwid' module"
mkdir -p "$HWID_DIR"

# Kconfig: must exist because drivers/misc/Kconfig sources it. Deliberately defines no
# symbols, so nothing new can be selected and no behaviour changes.
cat > "$HWID_DIR/Kconfig" <<'EOF'
# Placeholder for the Xiaomi `hwid` (hardware id) driver, which was NOT included in the
# MiCode mondrian-s-oss release but IS referenced by drivers/misc/Kconfig.
#
# This file intentionally defines no configuration symbols: the real module is absent, so
# there is nothing to enable. It exists purely so that Kconfig can be parsed and the
# kernel can be configured and built at all.
#
# Replace this directory with the real driver if you obtain it from a complete
# vendor kernel source drop.
EOF

# Makefile: required because drivers/misc/Makefile has an unconditional `obj-y += hwid/`.
# Contributes no objects.
cat > "$HWID_DIR/Makefile" <<'EOF'
# Placeholder - intentionally builds nothing.
# drivers/misc/Makefile has `obj-y += hwid/`, which requires a Makefile to exist here or
# kbuild fails with "No rule to make target 'drivers/misc/hwid/'". The real Xiaomi driver
# is not part of the public kernel source release.
EOF

# Header: drivers/misc/Makefile adds -I$(srctree)/drivers/misc/hwid/, and
# drivers/misc/gpio-testing-mode.c does `#include "hwid.h"` without using any symbol from
# it. An empty guarded header satisfies that include without affecting behaviour.
cat > "$HWID_DIR/hwid.h" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Placeholder header for the Xiaomi `hwid` driver, absent from the public
 * mondrian-s-oss kernel source release.
 *
 * drivers/misc/gpio-testing-mode.c includes "hwid.h" but references no symbol from it,
 * so this empty definition is sufficient and behaviour-preserving.
 */
#ifndef _PLACEHOLDER_HWID_H
#define _PLACEHOLDER_HWID_H

/* Intentionally empty - the real interface is not available. */

#endif /* _PLACEHOLDER_HWID_H */
EOF

echo "==> verify"
fail=0
for f in Kconfig Makefile hwid.h; do
	if [ -f "$HWID_DIR/$f" ]; then echo "  ok   drivers/misc/hwid/$f"; else echo "  FAIL drivers/misc/hwid/$f"; fail=1; fi
done
grep -q 'drivers/misc/hwid/Kconfig' "$KERNEL_DIR/drivers/misc/Kconfig" \
	&& echo "  ok   drivers/misc/Kconfig still sources it (now resolvable)" \
	|| echo "  note drivers/misc/Kconfig no longer references hwid"
grep -q 'obj-y.*+= hwid/' "$KERNEL_DIR/drivers/misc/Makefile" \
	&& echo "  ok   drivers/misc/Makefile obj-y += hwid/ now resolvable" \
	|| echo "  note drivers/misc/Makefile no longer references hwid"
[ "$fail" -eq 0 ] || { echo "ERROR: placeholder creation failed"; exit 1; }

echo ""
echo "==> NOTE: the Xiaomi hardware-id driver itself is still absent."
echo "    Nothing exports hardware-id sysfs nodes from this build. The kernel is expected"
echo "    to boot without it, but if userspace or a vendor HAL requires those nodes, obtain"
echo "    the real driver from a complete vendor kernel source drop and replace this stub."
