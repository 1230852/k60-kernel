#!/usr/bin/env bash
# Unbreak the build for driver directories that Xiaomi references but did not publish.
#
# BACKGROUND (evidence, not guesswork)
#   The MiCode `mondrian-s-oss` drop is incomplete - upstream issue
#   MiCode/Xiaomi_Kernel_OpenSource#5388 says as much ("big amount of changes missing /
#   not pushed"). Concretely, Kconfig/Makefile files reference driver directories whose
#   sources are absent, which aborts configuration with:
#       drivers/misc/Kconfig:540: can't open file "drivers/misc/hwid/Kconfig"
#       drivers/misc/Kconfig:542: can't open file "drivers/misc/plaid/Kconfig"
#       make[2]: *** [../scripts/kconfig/Makefile:71: olddefconfig] Error 1
#
# WHY A PLACEHOLDER IS ACCEPTABLE
#   `source "..."` in Kconfig is unconditional, so a missing file is a hard error. The
#   real drivers cannot be reconstructed from a public source. Creating an empty Kconfig,
#   an empty Makefile and (when the -I path is added) an empty header lets configuration
#   and compilation proceed without changing any behaviour:
#     * the placeholder Kconfig defines no symbols, so nothing new can be selected
#     * the placeholder Makefile contributes no objects
#     * the only consumer of the hwid header (drivers/misc/gpio-testing-mode.c) references
#       no symbol from it - verified by full-text search
#
# This script scans for EVERY missing Kconfig source in the tree rather than patching the
# two known cases, so a further unpublished module shows up here instead of in CI.
set -euo pipefail

KERNEL_DIR="${1:?usage: fix-missing-kconfig-dirs.sh <kernel-tree>}"
[ -d "$KERNEL_DIR/drivers/misc" ] || { echo "ERROR: $KERNEL_DIR/drivers/misc not found"; exit 1; }

	echo "==> scanning the whole tree for Kconfig sources that do not exist"

MISSING_FILE="$(mktemp)"
trap 'rm -f "$MISSING_FILE"' EXIT

# Collect every `source "..."` in the tree whose target is absent.
#
# Two classes of reference are deliberately skipped:
#   * paths containing make variables/functions - expanded at build time
#     (e.g. arch/$(SRCARCH)/Kconfig), not real filesystem references
#   * scripts/kconfig/tests/** - that directory intentionally contains unresolvable
#     relative includes (Kconfig.inc1 -> Kconfig.inc2 -> ... ) to test error handling.
#     Treating them as missing would create junk placeholder files at the tree root.
collect_missing() {
	while IFS= read -r kfile; do
		case "$kfile" in
			*/scripts/kconfig/tests/*) continue ;;
		esac
		while IFS= read -r src; do
			case "$src" in
				*'$('*|*'%'*) continue ;;
				/*) ;;                 # absolute: keep
				*)  ;;                 # relative: keep, resolved against the tree root
			esac
			[ -e "$KERNEL_DIR/$src" ] || printf '%s\n' "$src"
		done < <(grep -oE '^[[:space:]]*source[[:space:]]+"[^"]+"' "$kfile" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
	done < <(find "$KERNEL_DIR" -type f -name 'Kconfig*' 2>/dev/null) | sort -u
}

collect_missing > "$MISSING_FILE"

COUNT=$(grep -c . "$MISSING_FILE" || true)
echo "    missing Kconfig sources: $COUNT"
if [ "$COUNT" -eq 0 ]; then
	echo "==> nothing to do"
	exit 0
fi
sed 's/^/      /' "$MISSING_FILE"

# Second pass: create a placeholder directory for each missing source.
while IFS= read -r src; do
	[ -n "$src" ] || continue
	dir="$KERNEL_DIR/$(dirname "$src")"
	echo "==> placeholder: $dir"

	mkdir -p "$dir"

	if [ ! -f "$dir/Kconfig" ]; then
		cat > "$dir/Kconfig" <<EOF
# Placeholder for a driver directory referenced by the kernel's Kconfig but NOT shipped
# in the public Xiaomi mondrian-s-oss kernel source release.
#
# Intentionally defines no configuration symbols: the real driver is absent, so there is
# nothing to enable. It exists only so Kconfig can be parsed and the kernel can be built.
#
# Replace this directory wholesale if you obtain the real driver from a complete vendor
# kernel source drop.
EOF
	fi

	# A Makefile is required if any parent uses `obj-y += <dir>/`, otherwise kbuild aborts
	# with "No rule to make target". An empty one contributes no objects.
	if [ ! -f "$dir/Makefile" ]; then
		cat > "$dir/Makefile" <<EOF
# Placeholder - intentionally builds nothing.
# The real driver is not part of the public kernel source release, but kbuild requires a
# Makefile to exist whenever a parent Makefile recurses into this directory.
EOF
	fi

	# If a parent Makefile adds this directory to the include path, any header included
	# from it would fail. Provide an empty guarded header with the directory's own name.
	base=$(basename "$dir")
	hdr="$dir/$base.h"
	if [ ! -f "$hdr" ]; then
		cat > "$hdr" <<EOF
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Placeholder header for '$base', a driver absent from the public kernel source release.
 *
 * Callers that include this header without referencing any symbol from it compile
 * unchanged; this file deliberately declares nothing.
 */
#ifndef _PLACEHOLDER_$(echo "$base" | tr '[:lower:]-' '[:upper:]_')_H
#define _PLACEHOLDER_$(echo "$base" | tr '[:lower:]-' '[:upper:]_')_H

/* Intentionally empty - the real interface is not available. */

#endif
EOF
	fi
done < "$MISSING_FILE"

echo ""
echo "==> re-scan to confirm"
collect_missing > "$MISSING_FILE.rescan"
REMAIN=$(grep -c . "$MISSING_FILE.rescan" || true)
if [ "$REMAIN" -gt 0 ]; then
	sed 's/^/  STILL MISSING: /' "$MISSING_FILE.rescan"
fi
rm -f "$MISSING_FILE.rescan"
echo "    remaining missing: $REMAIN"
[ "$REMAIN" -eq 0 ] || { echo "ERROR: placeholders did not resolve every missing Kconfig source"; exit 1; }

echo ""
echo "==> NOTE: these Xiaomi drivers are still genuinely absent:"
sed 's/^/      /' "$MISSING_FILE"
echo "    The kernel should configure and build without them. If a vendor HAL or userspace"
echo "    component needs their sysfs/procfs nodes at runtime, obtain the real drivers from a"
echo "    complete vendor kernel source drop and replace the placeholder directories."
