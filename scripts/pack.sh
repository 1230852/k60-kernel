#!/usr/bin/env bash
# ============================================================================
#  打包 AnyKernel3 刷机包
#
#  采用 split_boot + flash_boot（只替换 boot.img 里的内核，不重打 ramdisk）：
#  SukiSU 是编进内核的（CONFIG_KSU=y），不依赖 ramdisk 补丁，
#  所以不动 ramdisk 是最安全、最不容易出问题的做法。
#
#  额外的驱动模块放进 zip 里的 k60-modules/ 目录（AK3 不会自动安装），
#  刷完后在内核管理器里手动 insmod 即可，同时也会单独上传成 artifact。
# ============================================================================
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="${OUT:-out}"
ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/osm0sis/AnyKernel3.git}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

for t in git zip; do
  command -v "$t" >/dev/null 2>&1 || die "缺少命令 '$t'（CI 上由 apt 安装 zip）"
done

mkdir -p "$WS/work"
STAGE="$WS/work/ak3"
rm -rf "$STAGE"

log "准备 AnyKernel3 模板"
git clone --depth 1 "$ANYKERNEL_REPO" "$STAGE"
rm -rf "$STAGE/.git" "$STAGE/.github"

IMG="$KERNEL_DIR/$OUT/arch/arm64/boot/Image.lz4"
[ -f "$IMG" ] || die "找不到内核镜像 $IMG"
cp -f "$IMG" "$STAGE/Image.lz4"
cp -f "$WS/anykernel/anykernel.sh" "$STAGE/anykernel.sh"
echo "[=] 内核镜像: $(ls -lh "$STAGE/Image.lz4" | awk '{print $5}')"

# 附带模块（可选）
if ls "$WS"/work/modules/*.ko >/dev/null 2>&1; then
  mkdir -p "$STAGE/k60-modules"
  cp -f "$WS"/work/modules/*.ko "$STAGE/k60-modules/"
  echo "[=] 附带模块: $(ls -1 "$STAGE/k60-modules" | tr '\n' ' ')"
fi

STAMP="$(date -u '+%Y%m%d-%H%M')"
# 与内核版本串保持一致: 5.10.270-android12-miwu-sukisu+bbg守护
NAME="K60-5.10.270-android12-miwu-sukisu+bbg-${STAMP}"

log "生成刷机包"
( cd "$STAGE" && zip -r9 "$WS/work/${NAME}.zip" . -x '*.git*' >/dev/null )
ZIP="$WS/work/${NAME}.zip"
[ -f "$ZIP" ] || die "打包失败"
echo "[+] $ZIP"
ls -lh "$ZIP"

# 便于后续步骤引用
echo "$ZIP" > "$WS/work/zip-path.txt"
{
  echo "zip_name=${NAME}.zip"
} > "$WS/work/build-info.txt"
