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
ENABLE_EXTRAS="${ENABLE_EXTRAS:-false}"
LTO_MODE="${LTO_MODE:-thin}"
DEBUG_INFO="${DEBUG_INFO:-false}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cd "$KERNEL_DIR"
CFG="$OUT/.config"

# ============================================================================
# 【关键修正】配置阶段必须用**和编译阶段完全相同**的工具链。
#
# 实测(CI run #12/#13 日志): 之前这里的 make olddefconfig 没有传 CC/LLVM,
# 于是 Kconfig 的"编译器能力探测"跑在宿主机的 x86 gcc 上:
#
#   config AS_HAS_ARMV8_5      def_bool $(as-instr, ...)
#   config ARM64_AS_HAS_MTE    def_bool $(as-instr, ...)
#   config CC_IS_CLANG         def_bool $(cc-option, ...)
#
# 这些全部判定为"不支持", 后果是最关键的几项被**静默按默认值处理**:
#
#   Use Branch Target Identification for kernel (ARM64_BTI_KERNEL) [Y/n/?] (NEW)
#   Memory Tagging Extension support          (ARM64_MTE)         [Y/n/?] (NEW)
#   Clang Shadow Call Stack                   (SHADOW_CALL_STACK) [N/y/?] (NEW)
#
# 原机是 CONFIG_CFI_CLANG=y / SHADOW_CALL_STACK=y / ARM64_BTI_KERNEL=y /
# ARM64_MTE=y / KASAN_HW_TAGS=y, 全都被丢成默认值 —— 编出来的内核和 ROM 里
# 闭源 vendor 模块的构建配置完全不一致, 这是"第一屏就重启"的直接原因。
#
# build.sh 里本来就导出了这套环境, 配置阶段漏了。这里补齐, 并把 make 统一成
# MAKE_CFG, 保证后续所有 make 调用都带同样的 CC/LLVM。
# ============================================================================
export PATH="$WS/toolchain/clang/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

# 编译器探测结果必须能直接看到, 否则这类问题还会再藏一次
echo "[=] clang: $(clang --version 2>/dev/null | head -n 1 || echo '<找不到 clang>')"
echo "[=] LLVM=$LLVM LLVM_IAS=$LLVM_IAS CROSS_COMPILE=$CROSS_COMPILE"

MAKE_CFG=(make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 CC="ccache clang")

# ============================================================================
# 让 git 工作树变干净。
# 内核版本串 = VERSION.PATCHLEVEL.SUBLEVEL + CONFIG_LOCALVERSION + SCM 后缀,
# 而 scripts/setlocalversion 在工作树"有改动"时会补一个 "+"。我们打了 BBG 补丁、
# 把 SukiSU-Ultra 挂成了 drivers/kernelsu 符号链接, 树必然是脏的。
# 提交一次就能消掉这个后缀(build.sh 里还有一道兜底, 保证最终串精确匹配)。
# ============================================================================
if [ -d "$KERNEL_DIR/.git" ]; then
  git -C "$KERNEL_DIR" add -A >/dev/null 2>&1 || true
  git -C "$KERNEL_DIR" -c user.name=k60-ci \
      -c user.email=k60-ci@users.noreply.github.com \
      commit -q -m "ci: integrate SukiSU-Ultra + Baseband-guard" >/dev/null 2>&1 || true
  _dirty=$(git -C "$KERNEL_DIR" status --porcelain 2>/dev/null | wc -l)
  echo "[=] git 工作树剩余改动: ${_dirty} 个 (0 = 干净)"
fi

# ============================================================================
# 内核版本串 —— 改成"构造上不可能错"
#
# Makefile:1443
#   filechk_kernel.release = echo "$(KERNELVERSION)$$(scripts/setlocalversion ...)"
# scripts/setlocalversion:200,203
#   res="${res}${CONFIG_LOCALVERSION}${LOCALVERSION}"
#   if test "$CONFIG_LOCALVERSION_AUTO" = "y"; then res="$res$(scm_version)"; fi
#
# 问题: setlocalversion 要 source include/config/auto.conf 才能读到这两个值,
# 而实测(CI run #15) auto.conf 有时是旧的 —— .config 里 LOCALVERSION_AUTO 已经
# 关掉, 脚本却读到 =y, 于是吐出 SCM 串 '-g242b97810776' 而不是我们的名字。
#
# 直接把脚本换成固定输出, 从此不依赖 git 状态 / LOCALVERSION_AUTO / auto.conf。
# CONFIG_LOCALVERSION 保持空, 避免和这里的输出重复。
# ============================================================================
WANT_LOCALVERSION='-android12-miwu-sukisu+bbg守护'
if [ -f scripts/setlocalversion ]; then
  cp -f scripts/setlocalversion scripts/setlocalversion.orig
  cat > scripts/setlocalversion <<EOF
#!/bin/sh
# 本项目自定义 (由 scripts/configure.sh 生成):
# 内核版本串固定为 5.10.270${WANT_LOCALVERSION}, 不追加任何 SCM 信息。
# 只查询 SCM 版本(供其他脚本调用)时输出空。
case "\$1" in
	-s|--short|--no-localversion)
		exit 0
		;;
esac
echo "${WANT_LOCALVERSION}"
exit 0
EOF
  chmod +x scripts/setlocalversion
  echo "[=] scripts/setlocalversion 已替换为固定输出: ${WANT_LOCALVERSION}"
  echo "[=]   实测输出: '$(sh scripts/setlocalversion "$PWD" 2>/dev/null)'"
fi

# ============================================================================
# 【关键修正】让 /proc/config.gz 反映真实构建配置
#
# 这棵树的 kernel/Makefile 被厂商改过:
#     $(obj)/config_data: $(srctree)/arch/arm64/configs/gki-stock_defconfig FORCE
# 内核标准写法应该是:
#     $(obj)/config_data: $(KCONFIG_CONFIG) FORCE
#
# kernel/configs.c 会把 kernel/config_data.gz 原样内嵌进 .rodata:
#     "IKCFG_ST" -> kernel_config_data -> "IKCFG_ED"
# 于是 /proc/config.gz 报出来的是 gki-stock_defconfig(约 700 行的片段),
# 而不是本次构建实际用的 .config(1800+ 个 =y)。
#
# 实测佐证: 我们编出来的镜像里 IKCFG 块 = 702 行 / 600 个 =y, 而且 run #2 与
# run #11 配置完全不同却字节一致 —— 因为来源是个固定文件, 与 .config 无关。
# 反观能正常开机且不弹窗的参考内核: 6810 行 / 1921 个 =y。
#
# 为什么这会导致开机弹窗:
#   Android 的 VINTF 校验 (system/libvintf) 正是读 /proc/config.gz, 去核对
#   vendor 兼容性矩阵里 <kernel><config><key>CONFIG_xxx</key> 的要求:
#     /proc/config.gz 缺项 -> VintfObject.verifyWithoutAvb() != 0
#     -> Build.isBuildConsistent() = false
#     -> 弹 "您的设备内部出现了问题。请联系您的设备制造商了解详情"
#   (Build.java 在 IS_TREBLE_ENABLED 时只走 VintfObject.verifyWithoutAvb())
#
# 改回标准写法即可; build.sh 里还有一道硬校验, 数字不对就构建失败。
# ============================================================================
if [ -f kernel/Makefile ]; then
  echo "[=] 修正 kernel/Makefile 的 config_data 依赖:"
  echo "[=]   改前: $(grep -m1 '^$(obj)/config_data:' kernel/Makefile || echo '<没找到>')"
  _cdl=$(grep -n '^$(obj)/config_data:' kernel/Makefile | head -1 | cut -d: -f1)
  if [ -n "$_cdl" ]; then
    cp -f kernel/Makefile kernel/Makefile.orig
    sed -i "${_cdl}s|.*|\$(obj)/config_data: \$(KCONFIG_CONFIG) FORCE|" kernel/Makefile
    echo "[=]   改后: $(sed -n "${_cdl}p" kernel/Makefile)"
  else
    echo "[!]   没找到 config_data 规则, /proc/config.gz 可能仍然不正确"
  fi
  grep -n 'config_data' kernel/Makefile | sed 's/^/       /'
fi

append_fragment() {
  local title="$1" file="$2"
  [ -f "$file" ] || die "片段文件不存在：$file"
  printf '\n# ======== %s (%s) ========\n' "$title" "$(basename "$file")" >> "$CFG"
  cat "$file" >> "$CFG"
  # 防御: 片段若不以换行结尾, 会跟下一条追加的内容粘成一行。
  # 实测踩到过: CONFIG_FRAME_WARN=0 与 '# CONFIG_KPM is not set' 粘成
  #   CONFIG_FRAME_WARN=0# CONFIG_KPM is not set
  # 导致 FRAME_WARN 报 "symbol value invalid", KPM 开关也被吞掉。
  if [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >> "$CFG"; fi
}

# ---------------------------------------------------------------------------
log "1/5 生成基线配置"
export ARCH=arm64
# 优先用小米原机内核里提取出来的真实配置当基线; 没有才退回通用 gki_defconfig。
# 原因: gki_defconfig 是 delta 式配置, 展开后的内建驱动集合与小米实际用的
# 差别很大(原机 raw Image 44.61MB vs 我们之前 29.8MB), 直接照抄原机配置
# 能让驱动集合/CFI/LTO 设置与原机一致, 是让整机能启动的最直接办法。
if [ -f "$WS/configs/k60-stock-baseline.config" ]; then
  echo "[= ] 使用原机真实配置作为基线: configs/k60-stock-baseline.config"
  mkdir -p "$OUT"
  cp -f "$WS/configs/k60-stock-baseline.config" "$CFG"
  "${MAKE_CFG[@]}" olddefconfig >/dev/null
else
  echo "[= ] 未找到原机配置, 退回 gki_defconfig"
  "${MAKE_CFG[@]}" gki_defconfig >/dev/null
fi

# ---- 诊断: 基线配置归一化后到底有多少配置项 ----
echo "[诊断] 基线配置之后: $(wc -l < "$CFG") 行, $(grep -c '^CONFIG_[A-Z0-9_]*=y$' "$CFG" || true) 个 =y"
[ -f "$CFG" ] || die "基线配置生成失败"

# 2/5 追加**树内**的厂商配置片段
#
# 坑(实测踩到): 不同内核树里这些配置的分布完全不同 ——
#   官方小米树 mondrian-s-oss:
#       vendor/mondrian_GKI.config 11.6KB / 62 个 =y, 什么都有
#   社区树 Kuroringo97:
#       vendor/mondrian_GKI.config 只剩 0.2KB / 4 个电源符号(内容被挪走),
#       真正的设备配置在 vendor/waipio_GKI.config (46 个 =y, 含
#       ARCH_WAIPIO / QCOM_DMABUF_HEAPS_* / QCOM_KGSL_* / ARM_SMMU_* /
#       FTS_TRUSTED_TOUCH / CNSS2_QMI 等显示-GPU-IOMMU-触控-WiFi 的内建驱动)
#       和 vendor/xiaomi_GKI.config。
#   旧版脚本写死只 cat mondrian_GKI.config —— 在官方树上没问题, 换到社区树
#   就等于一个设备配置都没生效, 编出来的内核缺设备内建驱动, 开机黑屏重启。
#   (体积佐证: 原机 raw Image 44.61MB, 官方树编出来 35.08MB,
#    社区树没配之前只有 29.8MB)
#
# 所以这里按高通 build.config.msm 的做法, 把 SoC / 厂商 / 设备三层片段都合并。
log "2/5 追加树内厂商配置片段"
# ============================================================================
# 【关键修正】这里原本会合并 waipio_GKI.config + xiaomi_GKI.config +
# mondrian_GKI.config 三层厂商片段(共 100+ 个 =y)。从用户原机内核提取出的
# 真实配置证明这是**错的**:
#
#   原机的架构选择:  CONFIG_ARCH_QCOM=y  CONFIG_ARCH_SUNXI=y
#                    CONFIG_ARCH_HISI=y  CONFIG_ARCH_SPRD=y
#                    CONFIG_ARCH_WAIPIO  ->  原机里【根本没有这一项】
#   原机的 WiFi:     cnss2 / icnss2 等都在 vendor_dlkm 的 .ko 里, 不在内核里
#
# 也就是说小米的 boot 内核是**纯 GKI 内核**, 高通平台代码全部走模块。
# 我们把 waipio/mondrian 片段合进来会:
#   1) 把内核的架构选择从通用 GKI 改成 waipio 专板 (影响最早期的板级初始化)
#   2) 把 CONFIG_CNSS2_QMI / CONFIG_QCOM_KGSL_* 等编成内建, 与 ROM 里
#      vendor_dlkm 的同名 .ko 重复 —— 同一个硬件被两套驱动抢
# 这两件事都可能让内核在 logo 阶段就挂掉。
#
# 所以这里刻意**不合并任何厂商片段**, 完全照抄原机的架构/驱动布局。
# ============================================================================
echo "[= ] 按原机布局: 不合并任何厂商片段 (原机是纯 GKI 内核)"



# ---------------------------------------------------------------------------
log "3/5 追加本项目片段"
append_fragment "SukiSU Ultra + BBG" "$WS/configs/k60-sukisu-bbg.config"
# 关闭 GKI 调试特性（KASAN/UBSAN_TRAP/KFENCE），否则内核又慢又会随机 panic
# 小米官方设备配置(62 个 =y 的设备内建驱动) —— 必须放在 k60-base 之前, 以免覆盖其关闭项
# 【同样停用】官方 mondrian 片段含 62 个 =y(ARCH_WAIPIO / QCOM_KGSL / CNSS2_QMI ...),
# 原机内核里这些都不是内建 —— 加了就与 ROM 的 .ko 冲突。
# append_fragment "小米官方 mondrian 设备配置" "$WS/configs/k60-official-device.config"
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

"${MAKE_CFG[@]}" olddefconfig >/dev/null

# ---- 硬断言: 展开后的配置必须像个正经 GKI 配置 ----
_CFG_LINES=$(wc -l < "$CFG")
_CFG_Y=$(grep -c '^CONFIG_[A-Z0-9_]*=y$' "$CFG" || true)
echo "[诊断] olddefconfig 之后: ${_CFG_LINES} 行, ${_CFG_Y} 个 =y"
echo "[诊断] 关键子系统自检:"
for _k in CONFIG_IRQ_DOMAIN CONFIG_SPARSE_IRQ CONFIG_THREAD_INFO_IN_TASK CONFIG_SWAP \
          CONFIG_ARCH_WAIPIO CONFIG_QCOM_DMABUF_HEAPS_SYSTEM CONFIG_ARM_SMMU_V3 \
          CONFIG_KSU CONFIG_BBG CONFIG_LSM; do
  printf '    %-36s %s\n' "$_k" "$(grep -m1 "^${_k}=" "$CFG" || echo '<缺失>')"
done
if [ "${_CFG_Y:-0}" -lt 1500 ]; then
  echo "[-] 配置展开失败: 只有 ${_CFG_Y} 个 =y, 正常 GKI 应该有 1800+ 个。"
  echo "    这说明 Kconfig 没有被完整解析 —— 编出来的内核会缺大量驱动, 必然无法开机。"
  echo "    直接失败, 不要浪费时间编译。"
  exit 1
fi
echo "[= ] 配置展开正常 (${_CFG_Y} 个 =y)"
# actions/upload-artifact 默认排除点开头的隐藏文件, 复制一份非隐藏名以便随 artifact 上传核查
cp -f "$CFG" "$OUT/config-final.txt" 2>/dev/null || true

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
    "${MAKE_CFG[@]}" olddefconfig >/dev/null

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

# ---- 调试选项: 必须与原机配置一致(应为开启) ----
# 旧脚本要求这些项**必须关闭**, 理由写在 configs/k60-base.config 里("日常可用性"
# 与"编译冲突")。但从用户原机 boot.img 提取出小米真实 .config 后发现:
#      CONFIG_KASAN=y  CONFIG_KASAN_HW_TAGS=y  CONFIG_KFENCE=y
#      CONFIG_UBSAN=y  CONFIG_UBSAN_TRAP=y     CONFIG_PAGE_OWNER=y ...
# 小米量产内核这些全都是打开的, 而 ROM 里的闭源 vendor 模块是小米用那份配置编的。
# 我们单方面关掉 = 内核与模块构建配置不一致 —— 这是四次构建全部"logo 一闪就重启"
# 的高度嫌疑原因。所以这里反过来断言它们**必须开着**。
echo "  --- 调试选项 (必须与原机配置一致 = 开启) ---"
for sym in CONFIG_KASAN CONFIG_KFENCE CONFIG_UBSAN CONFIG_UBSAN_TRAP; do
  if grep -q "^${sym}=y" "$CFG"; then
    printf '  [OK]   %-32s = y (与原机一致)\n' "$sym"
  else
    printf '  [FAIL] %-32s 应为 y —— 原机是 y, 关掉会与 vendor 模块的构建配置不一致\n' "$sym"
    missing="$missing $sym"
    FAILED=1
  fi
done
# KASAN_HW_TAGS 依赖 CONFIG_ARM64_MTE。实测(CI run #12)它被 olddefconfig 静默丢弃,
# 内核退化成软件 KASAN —— 会预留影子内存、大改早期内存布局, 是"第一屏就重启"的
# 高度嫌疑原因。所以从"只提示"改成**硬断言**。
echo "  --- KASAN 模式 (必须硬件 HW_TAGS, 与原机一致) ---"
for _pair in "CONFIG_KASAN_HW_TAGS=y" "CONFIG_ARM64_MTE=y"; do
  _s="${_pair%%=*}"; _v="${_pair#*=}"
  if [ "$(grep -m1 "^${_s}=" "$CFG" | cut -d= -f2-)" = "$_v" ]; then
    printf '  [OK]   %-32s = %s\n' "$_s" "$_v"
  else
    printf '  [FAIL] %-32s 应为 %s, 实际 %s  —— 软件 KASAN 会改变早期内存布局\n' \
      "$_s" "$_v" "$(grep -m1 "^${_s}=" "$CFG" | cut -d= -f2- || echo '<未设置>')"
    missing="$missing $_s"; FAILED=1
  fi
done
for _s in CONFIG_KASAN_GENERIC CONFIG_KASAN_SW_TAGS; do
  if grep -q "^${_s}=" "$CFG"; then
    printf '  [FAIL] %-32s 必须关闭(否则与 HW_TAGS 互斥)\n' "$_s"
    missing="$missing $_s"; FAILED=1
  else
    printf '  [OK]   %-32s 已关闭\n' "$_s"
  fi
done

# ---- LTO 模式: 必须与能开机的参考内核一致(thin) ----
if [ "$LTO_MODE" = "thin" ]; then
  echo "  --- LTO (thin, 与可开机参考内核一致) ---"
  for _pair in "CONFIG_LTO_CLANG_THIN=y"; do
    _s="${_pair%%=*}"; _v="${_pair#*=}"
    if [ "$(grep -m1 "^${_s}=" "$CFG" | cut -d= -f2-)" = "$_v" ]; then
      printf '  [OK]   %-32s = %s\n' "$_s" "$_v"
    else
      printf '  [FAIL] %-32s 应为 %s\n' "$_s" "$_v"
      missing="$missing $_s"; FAILED=1
    fi
  done
  if grep -q '^CONFIG_LTO_CLANG_FULL=' "$CFG"; then
    printf '  [FAIL] %-32s 必须关闭\n' CONFIG_LTO_CLANG_FULL
    missing="$missing CONFIG_LTO_CLANG_FULL"; FAILED=1
  else
    printf '  [OK]   %-32s 已关闭\n' CONFIG_LTO_CLANG_FULL
  fi
fi

# ---- 【关键】编译器能力相关的加固选项: 必须与原机一致 ----
# 这一类全部依赖 Kconfig 对编译器的探测 (CC_IS_CLANG / as-instr / cc-option)。
# 之前配置阶段用宿主 gcc 探测, 它们被静默按默认值处理 —— 原机全开, 我们全丢。
# 内核与 ROM 里闭源 vendor 模块的构建配置不一致 = 早期崩溃。
echo "  --- 编译器能力相关加固项 (必须与原机一致 = 开启) ---"
for sym in CONFIG_CFI_CLANG CONFIG_SHADOW_CALL_STACK CONFIG_ARM64_BTI_KERNEL \
           CONFIG_ARM64_PTR_AUTH CONFIG_LTO_CLANG CONFIG_CC_IS_CLANG; do
  if grep -q "^${sym}=y" "$CFG"; then
    printf '  [OK]   %-32s = y (与原机一致)\n' "$sym"
  else
    printf '  [FAIL] %-32s 应为 y —— 编译器探测没生效 (CC/LLVM 没传给 make?)\n' "$sym"
    missing="$missing $sym"
    FAILED=1
  fi
done

# ---- 内核版本串 ----
# 名字由被替换过的 scripts/setlocalversion 提供, 所以 CONFIG_LOCALVERSION 必须是空的
# (否则 setlocalversion:200 会把两者拼起来变成重复)。
echo "  --- 内核版本串 ---"
GOT_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$CFG" | head -n 1)"
if [ -z "$GOT_LOCALVERSION" ]; then
  printf '  [OK]   %-32s = "" (空, 名字由 setlocalversion 提供)\n' CONFIG_LOCALVERSION
else
  printf '  [FAIL] %-32s 必须为空, 实际 "%s" —— 会和 setlocalversion 的输出重复\n' \
    CONFIG_LOCALVERSION "$GOT_LOCALVERSION"
  missing="$missing CONFIG_LOCALVERSION"; FAILED=1
fi
if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "$CFG"; then
  # 按原机保持开启。版本串不受影响 —— scripts/setlocalversion 已被整个替换成
  # 固定输出, 它根本不读这个开关。开着的意义是让 MODULE_SCMVERSION
  # (depends on LOCALVERSION_AUTO) 能像原机一样生效。
  printf '  [OK]   %-32s = y (与原机一致; setlocalversion 已替换, 版本串不受影响)\n' CONFIG_LOCALVERSION_AUTO
else
  printf '  [FAIL] %-32s 应为 y —— 关掉会让 MODULE_SCMVERSION 失效, 与兼容性矩阵不一致\n' CONFIG_LOCALVERSION_AUTO
  missing="$missing CONFIG_LOCALVERSION_AUTO"; FAILED=1
fi

# ---- KPM (SukiSU 内核补丁模块) ----
if [ "$ENABLE_KPM" = "true" ]; then
  echo "  --- KPM (SukiSU 内核补丁模块) ---"
  for sym in CONFIG_KPM CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL; do
    if grep -q "^${sym}=y" "$CFG"; then
      printf '  [OK]   %-32s = y\n' "$sym"
    else
      printf '  [FAIL] %-32s 应为 y\n' "$sym"
      missing="$missing $sym"; FAILED=1
    fi
  done
fi

# ---- VINTF 相关项: Android 会读 /proc/config.gz 去核对兼容性矩阵 ----
echo "  --- VINTF 相关 (VintfObject.verifyWithoutAvb 会核对 /proc/config.gz) ---"
printf '  [i]   %-32s %s\n' CONFIG_MODULE_SCMVERSION \
  "$(grep -m1 '^CONFIG_MODULE_SCMVERSION=' "$CFG" || echo '<未设置>')"
printf '  [i]   %-32s %s\n' CONFIG_ANDROID_BINDERFS \
  "$(grep -m1 '^CONFIG_ANDROID_BINDERFS=' "$CFG" || echo '<未设置>')"
printf '  [i]   %-32s %s\n' CONFIG_ASHMEM \
  "$(grep -m1 '^CONFIG_ASHMEM=' "$CFG" || echo '<未设置>')"
printf '  [i]   %-32s %s\n' CONFIG_SECURITY_SAFESETID \
  "$(grep -m1 '^CONFIG_SECURITY_SAFESETID=' "$CFG" || echo '<未设置>')"

# ---- 这些项必须关闭: 有硬性理由 ----
# GPIO_TESTING_MODE : 官方树的该驱动引用小米未开源的 hwid 符号, 内建必编译失败
# TRIM_UNUSED_KSYMS : 需要小米编译机上的 KMI 白名单文件, 我们这边不存在
echo "  --- 必须有硬性理由关闭的项 ---"
for sym in CONFIG_GPIO_TESTING_MODE CONFIG_TRIM_UNUSED_KSYMS; do
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

# ---- 版本串预演: 直接跑(已被替换的) scripts/setlocalversion ----
# 目标最终串 = KERNELVERSION(5.10.270) + setlocalversion 的输出
WANT_SUFFIX='-android12-miwu-sukisu+bbg守护'
if [ -f "$KERNEL_DIR/scripts/setlocalversion" ]; then
  GOT_SUFFIX="$(sh "$KERNEL_DIR/scripts/setlocalversion" "$KERNEL_DIR" 2>/dev/null || true)"
  printf '  [i]   预演 setlocalversion -> %s\n' "'${GOT_SUFFIX}'"
  if [ "$GOT_SUFFIX" = "$WANT_SUFFIX" ]; then
    printf '  [OK]  最终内核版本串 = %s\n' "5.10.270${GOT_SUFFIX}"
  else
    printf '  [FAIL] 版本串预演不符: 期望 %s, 实际 %s\n' "'${WANT_SUFFIX}'" "'${GOT_SUFFIX}'"
    missing="$missing LOCALVERSION_SUFFIX"; FAILED=1
  fi
else
  printf '  [!]   跳过版本串预演 (缺 scripts/setlocalversion)\n'
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
