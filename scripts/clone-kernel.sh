#!/usr/bin/env bash
# ============================================================================
#  克隆小米官方内核源码（Redmi K60 / POCO F5 Pro = mondrian / SM8475）
#  基线：MiCode/Xiaomi_Kernel_OpenSource 分支 mondrian-s-oss  =  Linux 5.10.81
# ============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-mondrian-s-oss}"
KERNEL_SHA="${KERNEL_SHA:-989b27aa8391a2ede9b067b53877c4c3343955fe}"
KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

log "克隆内核源码 $KERNEL_BRANCH"
if [ ! -d "$KERNEL_DIR/.git" ]; then
  git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi

cd "$KERNEL_DIR"

# 尽量检出固定提交，保证可复现；失败则使用分支 HEAD
if ! git cat-file -e "${KERNEL_SHA}^{commit}" 2>/dev/null; then
  git fetch --depth 1 origin "$KERNEL_SHA" >/dev/null 2>&1 || true
fi
if git cat-file -e "${KERNEL_SHA}^{commit}" 2>/dev/null; then
  git checkout -q --force "$KERNEL_SHA"
  echo "[=] 已检出固定提交 $KERNEL_SHA"
else
  echo "[!] 无法取得固定提交 $KERNEL_SHA，改用分支 HEAD（Xiaomi 可能强推过分支）"
fi

git log -1 --format='[=] 内核源码: %H%n[=] 提交时间: %ci%n[=] 说明: %s'
echo "[=] 版本: $(sed -n 's/^VERSION = //p;' Makefile)$(sed -n 's/^PATCHLEVEL = /./p' Makefile | tr -d '\n')$(sed -n 's/^SUBLEVEL = /./p' Makefile | tr -d '\n')"

# 关键校验：这些路径是后续所有集成步骤的前提
for f in arch/arm64/configs/gki_defconfig \
         arch/arm64/configs/vendor/mondrian_GKI.config \
         drivers/Makefile drivers/Kconfig security/Makefile security/Kconfig \
         include/linux/lsm_hooks.h; do
  [ -e "$f" ] || { echo "[-] 源码结构异常，缺少 $f" >&2; exit 1; }
done
echo "[=] 源码结构校验通过（GKI + mondrian 合并布局）"
