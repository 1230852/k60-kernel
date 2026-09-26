#!/usr/bin/env bash
# ============================================================================
#  编译内核（LLVM=1 + LLVM_IAS=1，GCC 交叉工具链由 apt 提供）
#  产物：out/arch/arm64/boot/Image.lz4  (GKI boot.img 使用的内核格式)
#  另外按需编译"驱动补齐"模块（全部 =m，随包附带，不影响内核镜像）
# ============================================================================
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="${OUT:-out}"
ENABLE_USB_WIFI="${ENABLE_USB_WIFI:-true}"
MODULES_OUT="${MODULES_OUT:-$WS/work/modules}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

export PATH="$WS/toolchain/clang/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_ctime,include_file_mtime
export KBUILD_BUILD_USER=redmi-k60-ci
export KBUILD_BUILD_HOST=github-actions

mkdir -p "$CCACHE_DIR"
ccache --show-stats || true

cd "$KERNEL_DIR"

MAKE=(make -j"$(nproc)" -k O="$OUT" ARCH=arm64 CC="ccache clang")

log "编译内核（$(nproc) 线程，-k 模式：出错继续，一次性收集全部错误）"
echo "[=] clang: $(clang --version | head -n 1)"
echo "[=] 开始时间: $(date -u '+%F %T UTC')"

BUILD_LOG=/tmp/kernel-build.log
set +e
time "${MAKE[@]}" Image.lz4 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
  mkdir -p "$WS/work"
  cp -f "$BUILD_LOG" "$WS/work/kernel-build.log" 2>/dev/null || true
  echo
  echo "=========================================================="
  echo " 编译失败 —— -k 模式已尽可能收集所有错误（去重后列出）"
  echo "=========================================================="
  grep -aE 'error:|fatal error:|Error [0-9]+|No rule to make target|undefined reference' "$BUILD_LOG" \
    | sed 's/^\.\.\///; s/^ *//' | sort -u | head -120
  echo "=========================================================="
  echo " 完整日志已保存: $BUILD_LOG （并复制到 work/kernel-build.log 供 artifact 上传）"
  exit 1
fi

IMG="$OUT/arch/arm64/boot/Image.lz4"
[ -f "$IMG" ] || { echo "[-] 未生成 $IMG" >&2; exit 1; }
ls -lh "$IMG"

# ---------------------------------------------------------------------------
# 版本串硬校验
# 目标: 5.10.270-android12-miwu-sukisu+bbg守护
# 直接核对 utsrelease.h, 并确认这个串真的进了内核镜像(用未压缩的 Image 找,
# Image.lz4 是压缩的, grep 不到)。不对就直接失败, 绝不交付名字错误的内核。
# ---------------------------------------------------------------------------
WANT_UTS='5.10.270-android12-miwu-sukisu+bbg守护'
GOT_UTS="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$OUT/include/generated/utsrelease.h" 2>/dev/null || true)"
RAW_IMG="$OUT/arch/arm64/boot/Image"
echo "[=] utsrelease.h: '$GOT_UTS'"
echo "[=] 目标        : '$WANT_UTS'"
if [ "$GOT_UTS" != "$WANT_UTS" ]; then
  echo "[-] 版本串不匹配 —— 检查 CONFIG_LOCALVERSION 与 CONFIG_LOCALVERSION_AUTO"
  exit 1
fi
if [ -f "$RAW_IMG" ]; then
  if grep -aqF "$WANT_UTS" "$RAW_IMG"; then
    echo "[=] 已确认版本串写入内核镜像"
  else
    echo "[-] 未压缩 Image 里找不到该版本串 (可能没重新链接 version.o)"; exit 1
  fi
  ls -lh "$RAW_IMG"
fi

# ---------------------------------------------------------------------------
# /proc/config.gz 硬校验
#
# 这棵树的 kernel/Makefile 把 config_data 的依赖写成了 gki-stock_defconfig,
# 导致内核里内嵌的 IKCFG 块(也就是 /proc/config.gz 的内容)不是真实构建配置。
# Android 的 VINTF 校验正是读 /proc/config.gz, 缺项就会在开机时弹
# "您的设备内部出现了问题。请联系您的设备制造商了解详情"。
#
# 正常 GKI 配置展开后应有 1800+ 个 =y; 被厂商那条规则换掉的片段只有约 600 个。
# 这里直接把 IKCFG_ST..IKCFG_ED 拆出来 gunzip 数一遍, 不达标就让构建失败。
# ---------------------------------------------------------------------------
if [ -f "$RAW_IMG" ]; then
  python3 - "$RAW_IMG" <<'PY'
import gzip, sys
p = sys.argv[1]
data = open(p, 'rb').read()
s = data.find(b'IKCFG_ST')
e = data.find(b'IKCFG_ED', s + 8) if s >= 0 else -1
if s < 0 or e < 0:
    print('[-] 镜像里找不到 IKCFG_ST/IKCFG_ED —— CONFIG_IKCONFIG 没生效')
    print('    后果: /proc/config.gz 不存在, VINTF 校验无法核对内核配置')
    sys.exit(1)
try:
    cfg = gzip.decompress(data[s + 8:e]).decode('utf-8', 'replace')
except Exception as err:
    print('[-] IKCFG 块 gunzip 失败: %s' % err)
    sys.exit(1)
lines = [l for l in cfg.split('\n') if l.strip()]
ny = sum(1 for l in lines if l.endswith('=y'))
nm = sum(1 for l in lines if l.endswith('=m'))
print('[=] 内核内嵌配置 (/proc/config.gz): %d 行, %d 个 =y, %d 个 =m' % (len(lines), ny, nm))
for key in ('CONFIG_SYSVIPC', 'CONFIG_ANDROID_BINDERFS', 'CONFIG_ASHMEM',
            'CONFIG_DEBUG_FS', 'CONFIG_SECURITY_SELINUX', 'CONFIG_IKCONFIG_PROC'):
    hit = [l for l in lines if l.startswith(key + '=')]
    print('      %-28s %s' % (key, hit[0] if hit else '<缺失>'))
if ny < 1500:
    print('[-] 内嵌配置只有 %d 个 =y, 明显不是真实构建配置(应 1800+)。' % ny)
    print('    检查 kernel/Makefile 里 config_data 的依赖是否为 $(KCONFIG_CONFIG)')
    sys.exit(1)
print('[=] /proc/config.gz 校验通过')
PY
fi

# ---------------------------------------------------------------------------
# 驱动补齐模块：逐个目录用 M= 单独编译，避免整树 modules 的巨大耗时
if [ "$ENABLE_USB_WIFI" = "true" ]; then
  log "编译 USB 无线网卡模块"
  mkdir -p "$MODULES_OUT"
  MOD_DIRS=(
    drivers/staging/rtl8188eu
    drivers/net/wireless/realtek/rtl8xxxu
    drivers/net/wireless/ralink/rt2x00
    drivers/net/wireless/ath/ath9k
    drivers/net/wireless/mediatek/mt7601u
  )
  FAILED_DIRS=""
  for d in "${MOD_DIRS[@]}"; do
    [ -d "$d" ] || { echo "[!] 目录不存在，跳过：$d"; continue; }
    printf '[+] %-48s ' "$d"
    logf="/tmp/mod-$(echo "$d" | tr '/' '_').log"
    if "${MAKE[@]}" M="$d" modules >"$logf" 2>&1; then
      echo "OK"
    else
      echo "失败"
      tail -n 25 "$logf" | sed 's/^/      | /'
      FAILED_DIRS="$FAILED_DIRS $d"
    fi
  done

  # 收集所有 .ko（out/ 与源码树位置都找一遍）
  find "$KERNEL_DIR" -name '*.ko' -not -path '*/.git/*' -exec cp -f {} "$MODULES_OUT/" \; 2>/dev/null || true

  if [ -n "$FAILED_DIRS" ]; then
    echo
    echo "[!] 以下驱动目录编译失败（不影响内核镜像，但对应网卡不可用）："
    echo "   $FAILED_DIRS"
  fi
  echo "[=] 已收集模块："
  ls -1 "$MODULES_OUT" 2>/dev/null | sed 's/^/    /' || echo "    (无)"
fi

log "编译完成"
ccache --show-stats || true
