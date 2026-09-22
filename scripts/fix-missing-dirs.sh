#!/usr/bin/env bash
# ============================================================================
#  修复小米源码包不完整导致的编译中断
#
#  事实依据（本地扫描 68531 个文件得到，非猜测）：
#    drivers/misc/Kconfig  引用了 drivers/misc/hwid/Kconfig  -> 文件不存在
#    drivers/misc/Kconfig  引用了 drivers/misc/plaid/Kconfig -> 文件不存在
#    drivers/misc/Makefile:68  obj-y += hwid/               -> 无条件递归，必然报错
#    drivers/misc/Makefile:71  obj-$(CONFIG_XIAOMI_GPU_PLAID) += plaid/
#
#  后果：
#    make olddefconfig -> "can't open file drivers/misc/hwid/Kconfig"
#    make Image.lz4    -> "No rule to make target 'drivers/misc/hwid/'"
#
#  处理：为缺失目录生成"空占位"（Kconfig 不定义任何符号、Makefile 不产出任何目标），
#        这样配置与编译可以正常进行，且不改变任何行为。
# ============================================================================
set -euo pipefail

KERNEL_DIR="${1:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
cd "$KERNEL_DIR"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

log "扫描 Kconfig 中指向不存在文件的 source 引用"

MISSING="$(mktemp)"
trap 'rm -f "$MISSING"' EXIT

find . -type f -name 'Kconfig*' -not -path './scripts/kconfig/tests/*' -print0 2>/dev/null \
| xargs -0 grep -hoE '^[[:space:]]*source[[:space:]]+"[^"]+"' 2>/dev/null \
| sed -E 's/.*"([^"]+)".*/\1/' \
| grep -v '\$(' | grep -v '%' | sort -u \
| while IFS= read -r t; do
    [ -e "$t" ] || printf '%s\n' "$t"
  done > "$MISSING" || true

COUNT="$(grep -c . "$MISSING" || true)"
echo "[=] 缺失的 Kconfig 源文件: $COUNT"
sed 's/^/      /' "$MISSING" || true

if [ "$COUNT" -eq 0 ]; then
  log "无缺失，跳过"
  exit 0
fi

log "生成占位目录"
while IFS= read -r src; do
  [ -n "$src" ] || continue
  dir="$(dirname "$src")"
  base="$(basename "$dir")"
  echo "[+] $dir"
  mkdir -p "$dir"

  [ -f "$dir/Kconfig" ] || cat > "$dir/Kconfig" <<EOF
# 占位文件：小米 mondrian-s-oss 开源包引用了本目录，但未发布其源码。
# 这里不定义任何配置符号，仅让 Kconfig 能被正常解析。
# 若日后拿到完整厂商源码，直接整体替换本目录即可。
EOF

  # 关键：父 Makefile 里有 obj-y += $base/，没有 Makefile 会直接 "No rule to make target"
  [ -f "$dir/Makefile" ] || cat > "$dir/Makefile" <<EOF
# 占位文件：本目录源码未随公开内核包发布，此处不编译任何目标。
EOF

  # 若有代码 include 本目录的头文件，提供空头文件避免找不到
  HDR="$dir/$base.h"
  [ -f "$HDR" ] || cat > "$HDR" <<EOF
/* SPDX-License-Identifier: GPL-2.0 */
/* 占位头文件：'$base' 未随公开源码发布，故意不声明任何符号。 */
#ifndef _PLACEHOLDER_$(printf '%s' "$base" | tr '[:lower:]-' '[:upper:]_')_H
#define _PLACEHOLDER_$(printf '%s' "$base" | tr '[:lower:]-' '[:upper:]_')_H
#endif
EOF
done < "$MISSING"

log "复检"
REMAIN=0
while IFS= read -r src; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || { echo "  [仍然缺失] $src"; REMAIN=1; }
done < "$MISSING"

[ "$REMAIN" -eq 0 ] || { echo "[-] 仍有缺失，请人工处理" >&2; exit 1; }

# 二次确认：Makefile 递归引用的目录必须都存在（防止 make 报 No rule to make target）
log "复核 Makefile 递归目录"
BAD=0
while IFS= read -r line; do
  mkfile="${line%%:*}"
  rest="${line#*:}"
  sub="$(printf '%s' "$rest" | sed -E 's/.*\+=[[:space:]]*([A-Za-z0-9_.\/-]+)\/[[:space:]]*$/\1/')"
  [ -n "$sub" ] || continue
  dir="$(dirname "$mkfile")"
  [ -d "$dir/$sub" ] || { echo "  [缺目录] $dir/$sub"; BAD=1; }
done < <(grep -rEn '^[[:space:]]*obj-[^=]*\+=[[:space:]]*[A-Za-z0-9_./-]+/[[:space:]]*$' \
           --include='Makefile*' . 2>/dev/null | sed 's|^\./||')
[ "$BAD" -eq 0 ] && echo "[=] 所有被递归引用的目录均存在"

echo "[+] 修复完成"
