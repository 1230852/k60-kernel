#!/usr/bin/env bash
# ============================================================================
#  生成内核配置（官方 gki_defconfig + 厂商 mondrian_GKI.config + 本项目片段）
#
#  与 AOSP build.sh 的 apply_defconfig_fragment 行为一致：
#  把片段直接追加到 .config 末尾再 olddefconfig（kconfig 后者覆盖前者）。
#
#  最后有一道"配置闸门"：任何一项没生效都会立刻失败，
#  避免出现"编译成功但功能没进去"的静默失效。
# ============================================================================
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
WS="${GITHUB_WORKSPACE:-$PWD}"
OUT="${OUT:-out}"

ENABLE_BBG="${ENABLE_BBG:-true}"
ENABLE_KPM="${ENABLE_KPM:-true}"
ENABLE_SUSFS="${ENABLE_SUSFS:-false}"
ENABLE_USB_WIFI="${ENABLE_USB_WIFI:-true}"
ENABLE_EXTRAS="${ENABLE_EXTRAS:-true}"
LTO_MODE="${LTO_MODE:-thin}"
DEBUG_INFO="${DEBUG_INFO:-false}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cd "$KERNEL_DIR"
CFG="$OUT/.config"

# ---------------------------------------------------------------------------
log "1/5 生成 GKI 基线配置"
export ARCH=arm64
make O="$OUT" ARCH=arm64 gki_defconfig >/dev/null
[ -f "$CFG" ] || die "gki_defconfig 生成失败"

log "2/5 追加小米厂商片段 vendor/mondrian_GKI.config"
{
  printf '\n# ======== Xiaomi vendor fragment ========\n'
  cat arch/arm64/configs/vendor/mondrian_GKI.config
} >> "$CFG"

append_fragment() {
  local title="$1" file="$2"
  [ -f "$file" ] || die "片段文件不存在：$file"
  printf '\n# ======== %s (%s) ========\n' "$title" "$(basename "$file")" >> "$CFG"
  cat "$file" >> "$CFG"
}

# ---------------------------------------------------------------------------
log "3/5 追加本项目片段"
append_fragment "SukiSU Ultra + BBG" "$WS/configs/k60-sukisu-bbg.config"
# 关闭 GKI 调试特性（KASAN/UBSAN_TRAP/KFENCE），否则内核又慢又会随机 panic
append_fragment "日常可用性基线" "$WS/configs/k60-base.config"

if [ "$ENABLE_EXTRAS" = "true" ]; then
  append_fragment "网络增强驱动补齐" "$WS/configs/k60-extras.config"
fi

if [ "$ENABLE_SUSFS" = "true" ]; then
  append_fragment "SUSFS" "$WS/configs/k60-susfs.config"
fi

# KPM 开关（SukiSU 的 Kconfig: config KPM）
if [ "$ENABLE_KPM" = "true" ]; then
  echo 'CONFIG_KPM=y' >> "$CFG"
else
  echo '# CONFIG_KPM is not set' >> "$CFG"
fi

# 未启用 BBG 时，把 BBG 相关符号关掉，避免依赖残留
if [ "$ENABLE_BBG" != "true" ]; then
  {
    echo '# CONFIG_BBG is not set'
    echo '# CONFIG_BBG_BLOCK_BOOT is not set'
    echo '# CONFIG_BBG_BLOCK_RECOVERY is not set'
  } >> "$CFG"
fi

# ---------------------------------------------------------------------------
log "4/5 应用 LTO / 调试信息选项"
case "$LTO_MODE" in
  full)
    echo 'CONFIG_LTO_CLANG_FULL=y' >> "$CFG"
    echo '# CONFIG_LTO_CLANG_THIN is not set' >> "$CFG"
    ;;
  thin)
    # 与官方 full LTO 相比：内核 ABI/vermagic 完全一致，但链接更快、内存占用更低
    echo 'CONFIG_LTO_CLANG_THIN=y' >> "$CFG"
    echo '# CONFIG_LTO_CLANG_FULL is not set' >> "$CFG"
    ;;
  none)
    echo '# CONFIG_LTO_CLANG_FULL is not set' >> "$CFG"
    echo '# CONFIG_LTO_CLANG_THIN is not set' >> "$CFG"
    echo '# CONFIG_CFI_CLANG is not set' >> "$CFG"
    ;;
  *)
    die "未知 LTO 模式：$LTO_MODE（可选 full / thin / none）"
    ;;
esac

if [ "$DEBUG_INFO" != "true" ]; then
  # 仅影响调试符号，不影响内核运行行为；CI 上可省下十几 GB 磁盘
  {
    echo '# CONFIG_DEBUG_INFO is not set'
    echo '# CONFIG_DEBUG_INFO_DWARF4 is not set'
  } >> "$CFG"
fi

make O="$OUT" ARCH=arm64 olddefconfig >/dev/null

# ---------------------------------------------------------------------------
# BBG 硬性要求：CONFIG_BBG=y 时 CONFIG_LSM 必须包含 baseband_guard，
# 否则 BBG 的 Makefile 会 $(error) 直接中断编译。
if [ "$ENABLE_BBG" = "true" ] && grep -q '^CONFIG_BBG=y' "$CFG"; then
  cur_lsm="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' "$CFG" | head -n 1)"
  if [ -z "$cur_lsm" ]; then
    echo "[!] 未读到 CONFIG_LSM，使用内核默认顺序"
    cur_lsm="lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"
  fi
  if ! printf '%s' "$cur_lsm" | grep -q 'baseband_guard'; then
    printf 'CONFIG_LSM="%s,baseband_guard"\n' "$cur_lsm" >> "$CFG"
    make O="$OUT" ARCH=arm64 olddefconfig >/dev/null
    echo "[=] CONFIG_LSM 已追加 baseband_guard"
  fi
fi

# ---------------------------------------------------------------------------
log "5/5 配置闸门校验"
CHECKS="
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_MODULES=y
CONFIG_MODVERSIONS=y
CONFIG_MODULE_UNLOAD=y
CONFIG_PREEMPT=y
CONFIG_EXT4_FS=y
CONFIG_SECURITY=y
"

if [ "$ENABLE_KPM" = "true" ]; then CHECKS="$CHECKS
CONFIG_KPM=y"; fi
if [ "$ENABLE_BBG" = "true" ]; then CHECKS="$CHECKS
CONFIG_BBG=y"; fi
if [ "$ENABLE_SUSFS" = "true" ]; then CHECKS="$CHECKS
CONFIG_KSU_SUSFS=y"; fi
if [ "$ENABLE_EXTRAS" = "true" ]; then CHECKS="$CHECKS
CONFIG_TCP_CONG_BBR=y
CONFIG_IP_SET=y
CONFIG_NETFILTER_XT_SET=y"; fi
if [ "$ENABLE_USB_WIFI" = "true" ]; then CHECKS="$CHECKS
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_R8188EU=m
CONFIG_RTL8XXXU=m
CONFIG_RT2X00=m
CONFIG_RT2800USB=m
CONFIG_ATH9K_HTC=m
CONFIG_MT7601U=m"; fi

FAILED=0
missing=""
while IFS='=' read -r sym want; do
  [ -n "$sym" ] || continue
  got="$(grep -m1 "^${sym}=" "$CFG" | cut -d= -f2- || true)"
  if [ "$got" = "$want" ]; then
    printf '  [OK]   %-32s = %s\n' "$sym" "$got"
  else
    printf '  [FAIL] %-32s 期望 %s，实际 %s\n' "$sym" "$want" "${got:-<未设置>}"
    missing="$missing $sym"
  fi
done <<< "$CHECKS"

[ -n "$missing" ] && FAILED=1

# 必须为"关闭"的调试项：GKI 基线默认开着，会把内核变慢并在 UB 时直接 panic
for sym in CONFIG_KASAN CONFIG_KASAN_HW_TAGS CONFIG_KFENCE CONFIG_UBSAN CONFIG_UBSAN_TRAP CONFIG_GPIO_TESTING_MODE; do
  if grep -q "^${sym}=" "$CFG"; then
    printf '  [FAIL] %-32s 应为关闭，实际已开启\n' "$sym"
    missing="$missing $sym"
    FAILED=1
  else
    printf '  [OK]   %-32s 已关闭\n' "$sym"
  fi
done

if [ "$ENABLE_BBG" = "true" ]; then
  if grep -m1 '^CONFIG_LSM=' "$CFG" | grep -q 'baseband_guard'; then
    printf '  [OK]   %-32s = %s\n' CONFIG_LSM "$(grep -m1 '^CONFIG_LSM=' "$CFG")"
  else
    echo "  [FAIL] CONFIG_LSM 缺少 baseband_guard"
    FAILED=1
  fi
fi

if [ "$FAILED" != "0" ]; then
  echo
  echo "[-] 以下配置未生效：$(printf '%s' "$missing" | tr '\n' ' ')"
  echo "[-] 常见原因：依赖未满足（例如 CFG80211 不是 =m 会导致无线驱动被丢弃）。"
  exit 1
fi

log "配置生成完毕"
echo "[=] 内核版本: $(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$OUT/include/generated/utsrelease.h" 2>/dev/null || echo '（编译后生成）')"
echo "[=] 关键项:"
grep -E '^CONFIG_(LTO_CLANG\w*|CFI_CLANG|LOCALVERSION|LSM|BBG|KSU|KPM|TCP_CONG_BBR)=' "$CFG" | sed 's/^/    /'
