#!/usr/bin/env bash
# ============================================================================
#  【可选】编译外置 RTL8812AU / RTL8821AU / RTL8814AU (88XXAU) 驱动
#
#  为什么必须外置：这三个芯片的主线驱动在 5.10 里根本不存在，
#  只能拿 aircrack-ng 的第三方驱动编成模块。85XX/88XXAU 是做
#  监听模式 / 数据包注入最常用的网卡。
#
#  该步骤被 workflow 标记为 continue-on-error，失败不影响内核镜像与刷机包。
# ============================================================================
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="${OUT:-out}"
DRV_REPO="${RTL8812AU_REPO:-https://github.com/aircrack-ng/rtl8812au.git}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

export PATH="$WS/toolchain/clang/bin:$PATH"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_COMPILERCHECK=content

DRV_DIR="$WS/work/rtl8812au"
rm -rf "$DRV_DIR"
log "克隆 88XXAU 驱动源码"
git clone --depth 1 "$DRV_REPO" "$DRV_DIR"
git -C "$DRV_DIR" log -1 --format='[=] %H %s'

mkdir -p "$WS/work/modules"

log "以外置模块方式编译（针对本次构建的内核）"
cd "$KERNEL_DIR"
make -j"$(nproc)" O="$OUT" ARCH=arm64 M="$DRV_DIR" \
     CC="ccache clang" LLVM=1 LLVM_IAS=1 \
     CROSS_COMPILE=aarch64-linux-gnu- modules

found=0
while IFS= read -r ko; do
  cp -f "$ko" "$WS/work/modules/"
  echo "[+] $(basename "$ko")"
  found=1
done < <(find "$DRV_DIR" -name '*.ko' -print)

[ "$found" = "1" ] || { echo "[-] 未生成任何 .ko" >&2; exit 1; }
echo "[+] 88XXAU 模块编译完成"
