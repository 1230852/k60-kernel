#!/usr/bin/env bash
# Integrate Baseband-guard (BBG) into a kernel tree without git.
#
# BBG is a Linux Security Module that blocks writes to protected block devices.
# Mechanism (read from source, vc-teahouse/Baseband-guard):
#   hooks: file_permission, inode_setattr, file_ioctl (+ cred_prepare/transfer,
#          bprm_creds_for_exec) via DEFINE_LSM + security_add_hooks
#   policy: DEFAULT-DENY. baseband_guard.h holds an ALLOWLIST of writable partitions
#           (boot/init_boot/vendor_boot/dtbo/userdata/cache/metadata/misc/vbmeta*/
#           recovery). Everything else - i.e. modem, fsg, persist, abl, xbl, etc. -
#           is protected by default. That is exactly the "protect the baseband" behaviour.
#   trust:  a process is "untrusted" if its SELinux domain is su / ksu / magisk.
#           Trusted processes bypass; untrusted ones hit the allowlist check.
#           So this specifically stops a ROOT process from touching the baseband.
#
# The three things upstream setup.sh does:
#   1. vendor the repo to security/baseband-guard (upstream symlinks ../Baseband-guard)
#   2. append `obj-$(CONFIG_BBG) += baseband-guard/` to security/Makefile
#   3. insert `source "security/baseband-guard/Kconfig"` before the LAST endmenu
#      in security/Kconfig
#
# KERNEL VERSION NOTE: on 5.10 `#define DEFINE_LSM(lsm)` exists, so the modern LSM blob
# path is used and the SELinux objsec.h patch (sepatch.txt) is correctly SKIPPED.
# This is the same branch upstream setup.sh takes ("Modern LSM infrastructure detected").
#
# CONFIG_LSM: BBG's Makefile has a hard `$(error)` gate - it ABORTS the build if
# DEFINE_LSM exists and CONFIG_LSM does not contain "baseband_guard". The caller must
# therefore also set CONFIG_LSM (done via the defconfig fragment, not by sed-ing
# security/Kconfig, which upstream itself warns corrupts the defaults).
set -euo pipefail

KERNEL_DIR="${1:?usage: integrate-bbg.sh <kernel-tree> <bbg-repo-root>}"
BBG_SRC="${2:?missing baseband-guard repo root}"

SEC="$KERNEL_DIR/security"
DST="$SEC/baseband-guard"

[ -d "$SEC" ]      || { echo "ERROR: $SEC not found"; exit 1; }
[ -f "$BBG_SRC/baseband_guard.c" ] || { echo "ERROR: $BBG_SRC/baseband_guard.c not found"; exit 1; }
[ -f "$BBG_SRC/Kconfig" ]          || { echo "ERROR: $BBG_SRC/Kconfig not found"; exit 1; }
[ -f "$BBG_SRC/Makefile" ]         || { echo "ERROR: $BBG_SRC/Makefile not found"; exit 1; }

echo "==> step 1: vendor Baseband-guard into security/baseband-guard"
rm -rf "$DST"
mkdir -p "$DST"
# Copy sources, excluding VCS/build noise. Keep tracing/ (compiled into bbg.o).
tar -C "$BBG_SRC" \
	--exclude='./.git' --exclude='./.github' --exclude='./docs' \
	--exclude='*.tar.gz' --exclude='*.zip' --exclude='*.o' --exclude='*.ko' \
	-cf - . | tar -C "$DST" -xf -
echo "    $(find "$DST" -type f | wc -l) files: $(find "$DST" -type f -printf '%P ' 2>/dev/null | head -c 300)"

echo "==> step 2: patch security/Makefile"
if grep -q 'baseband-guard' "$SEC/Makefile"; then
	echo "    already present, skipping"
else
	printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> "$SEC/Makefile"
	echo "    appended obj-\$(CONFIG_BBG) += baseband-guard/"
fi

echo "==> step 3: patch security/Kconfig (insert before LAST endmenu)"
if grep -q 'security/baseband-guard/Kconfig' "$SEC/Kconfig"; then
	echo "    already present, skipping"
else
	# Insert before the LAST endmenu. awk is used rather than python3 so this works on
	# minimal build hosts and inside Git Bash, where python3 is not guaranteed.
	awk '
		{ a[NR] = $0 }
		END {
			last = 0
			for (i = 1; i <= NR; i++) if (a[i] ~ /^endmenu[[:space:]]*$/) last = i
			if (last == 0) {
				print "ERROR: no endmenu found in security/Kconfig" > "/dev/stderr"
				exit 1
			}
			for (i = 1; i <= NR; i++) {
				if (i == last) print "source \"security/baseband-guard/Kconfig\""
				print a[i]
			}
		}
	' "$SEC/Kconfig" > "$SEC/Kconfig.tmp" || { echo "ERROR: Kconfig patch failed"; rm -f "$SEC/Kconfig.tmp"; exit 1; }
	mv "$SEC/Kconfig.tmp" "$SEC/Kconfig"
	echo "    inserted source \"security/baseband-guard/Kconfig\" before endmenu"
fi

echo "==> step 4: confirm SELinux objsec patch is NOT needed on this kernel"
if grep -q '#define DEFINE_LSM(lsm)' "$KERNEL_DIR/include/linux/lsm_hooks.h"; then
	echo "    DEFINE_LSM present -> modern LSM blob path, sepatch.txt correctly skipped"
else
	echo "    ERROR: DEFINE_LSM absent; this old-kernel path is NOT implemented here."
	echo "    The sepatch.txt SELinux patch would be required and is untested."
	exit 1
fi

echo "==> verify BBG integration"
fail=0
chk() { if [ -e "$2" ] || [ -n "${3:-}" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }
[ -f "$DST/baseband_guard.c" ] && echo "  ok   baseband_guard.c" || { echo "  FAIL baseband_guard.c"; fail=1; }
[ -f "$DST/baseband_guard.h" ] && echo "  ok   baseband_guard.h" || { echo "  FAIL baseband_guard.h"; fail=1; }
[ -f "$DST/blkdev_helper.c" ]  && echo "  ok   blkdev_helper.c"  || { echo "  FAIL blkdev_helper.c"; fail=1; }
[ -f "$DST/tracing/tracing.c" ] && echo "  ok   tracing/tracing.c" || { echo "  FAIL tracing/tracing.c"; fail=1; }
[ -f "$DST/Kconfig" ]          && echo "  ok   Kconfig"           || { echo "  FAIL Kconfig"; fail=1; }
grep -q 'baseband-guard' "$SEC/Makefile" && echo "  ok   security/Makefile hook" || { echo "  FAIL Makefile hook"; fail=1; }
grep -q 'security/baseband-guard/Kconfig' "$SEC/Kconfig" && echo "  ok   security/Kconfig hook" || { echo "  FAIL Kconfig hook"; fail=1; }
[ "$fail" -eq 0 ] || { echo "ERROR: BBG integration verification failed"; exit 1; }

echo "==> Baseband-guard integration complete (remember CONFIG_BBG=y and CONFIG_LSM=...,baseband_guard)"
