#!/usr/bin/env bash
# ============================================================================
#  准备 LLVM(clang) + GCC 工具链
#
#  本内核基线 = android12-5.10 / KMI gen 9，官方 build.config.common 指定：
#      LLVM=1  LLVM_IAS=1  CLANG_PREBUILT_BIN=.../clang-r416183b/bin
#      CROSS_COMPILE=aarch64-linux-gnu-   CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
#
#  【为什么必须用 clang-r416183b(clang 12)】
#  基线 gki_defconfig 同时开启了 CONFIG_LTO_CLANG_FULL=y 与 CONFIG_CFI_CLANG=y。
#  5.10 使用的是旧版 CFI(-fsanitize=cfi)，该选项在 clang 16+ 已被移除。
#  换成新版 clang 会直接编译失败 —— 所以这里锁定 AOSP 官方配套版本。
#  GCC(aarch64-linux-gnu / arm-linux-gnueabi) 由 apt 提供，与 LLVM 组合使用。
# ============================================================================
set -euo pipefail

CLANG_TAG="${CLANG_TAG:-clang-r416183b}"
CLANG_MIRROR_BRANCH="${CLANG_MIRROR_BRANCH:-lineage-20.0}"
DEST="${GITHUB_WORKSPACE:-$PWD}/toolchain"
mkdir -p "$DEST"
cd "$DEST"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

if [ -x clang/bin/clang ]; then
  log "clang 工具链已存在，跳过下载"
  clang/bin/clang --version | head -n 1
  exit 0
fi

rm -rf clang clang.tar.gz

URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master/${CLANG_TAG}.tar.gz"
log "下载 AOSP ${CLANG_TAG}"
if curl -fLsS --retry 3 --retry-delay 5 --connect-timeout 20 -o clang.tar.gz "$URL"; then
  mkdir -p clang
  tar -xzf clang.tar.gz -C clang
  rm -f clang.tar.gz
  echo "[+] AOSP 源下载完成"
else
  log "AOSP 源不可用，回退到 LineageOS GitHub 镜像"
  rm -rf clang clang.tar.gz
  git clone --depth 1 -b "$CLANG_MIRROR_BRANCH" \
    "https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_${CLANG_TAG}.git" clang
fi

if [ ! -x clang/bin/clang ]; then
  echo "[-] clang 工具链准备失败：$DEST/clang/bin/clang 不存在" >&2
  exit 1
fi

log "工具链就绪"
clang/bin/clang --version | head -n 2
echo "GCC: $(aarch64-linux-gnu-gcc --version | head -n 1)"
echo "GCC(arm32): $(arm-linux-gnueabi-gcc --version | head -n 1)"
