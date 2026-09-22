#!/usr/bin/env bash
# ============================================================================
#  集成 SukiSU Ultra / KPM / Baseband Guard(BBG) / SUSFS
#
#  设计要点：
#   * SukiSU 走 kprobe 钩子 —— 基线 gki_defconfig 已有 CONFIG_KPROBES=y，
#     所以【完全不修改内核源码】，只做 symlink + Makefile/Kconfig 挂载。
#   * BBG 使用 DEFINE_LSM（5.10 有现代 LSM 框架），无需打 SELinux 补丁。
#   * BBG 的 Makefile 检测到浅克隆会执行 git fetch --unshallow，所以完整克隆。
# ============================================================================
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
WS="${GITHUB_WORKSPACE:-$PWD}"
ENABLE_BBG="${ENABLE_BBG:-true}"
ENABLE_SUSFS="${ENABLE_SUSFS:-false}"

SUKISU_REPO="${SUKISU_REPO:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
SUKISU_REF="${SUKISU_REF:-v4.2.0}"
BBG_REPO="${BBG_REPO:-https://github.com/vc-teahouse/Baseband-guard.git}"
BBG_SHA="${BBG_SHA:-a54e0dc6cf0aff4dd87fec49644a02d2eb612905}"
SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_BRANCH="${SUSFS_BRANCH:-gki-android12-5.10}"

log() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# 在文件的“最后一个”顶层 endmenu 之前插入一行（没有 endmenu 则追加到末尾）
insert_before_last_endmenu() {
  local file="$1" line="$2"
  if grep -qF "$line" "$file"; then
    echo "[=] $file 已包含该条目，跳过"
    return 0
  fi
  awk -v ins="$line" '
    { a[NR]=$0 }
    END {
      if (NR == 0) { print ins; exit }
      last = 0
      for (i = 1; i <= NR; i++) if (a[i] ~ /^endmenu[[:space:]]*$/) last = i
      if (last == 0) { for (i = 1; i <= NR; i++) print a[i]; print ins; exit }
      for (i = 1; i <= NR; i++) { if (i == last) print ins; print a[i] }
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  echo "[=] 已更新 $file"
}

cd "$KERNEL_DIR"

# ---------------------------------------------------------------------------
# 本树兼容性补丁：小米发布包自身的源码矛盾（与 SukiSU/BBG 无关）
log "0/4 应用本树兼容性补丁"
shopt -s nullglob
COMPAT_PATCHES=("$WS"/patches/[0-9][0-9]-*.patch)
shopt -u nullglob
if [ "${#COMPAT_PATCHES[@]}" -eq 0 ]; then
  echo "[=] 无兼容性补丁"
else
  for p in "${COMPAT_PATCHES[@]}"; do
    if patch -p1 --forward --no-backup-if-mismatch < "$p"; then
      echo "[+] $(basename "$p")"
    else
      die "兼容性补丁应用失败: $(basename "$p")"
    fi
  done
fi

# ---------------------------------------------------------------------------
log "1/4 集成 SukiSU Ultra（ref=$SUKISU_REF）"
rm -rf KernelSU
if ! git clone --depth 1 --branch "$SUKISU_REF" "$SUKISU_REPO" KernelSU 2>/dev/null; then
  echo "[!] 直接按 ref 浅克隆失败，改为完整克隆后检出"
  git clone "$SUKISU_REPO" KernelSU
  git -C KernelSU checkout --force "$SUKISU_REF"
fi
git -C KernelSU log -1 --format='[=] SukiSU: %H  %ci  %s'
[ -f KernelSU/kernel/Kconfig ] || die "SukiSU 结构异常：缺少 KernelSU/kernel/Kconfig"

ln -sfn ../KernelSU/kernel drivers/kernelsu
[ -e drivers/kernelsu/Kconfig ] || die "drivers/kernelsu 软链接无效"

grep -q 'kernelsu' drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
insert_before_last_endmenu drivers/Kconfig 'source "drivers/kernelsu/Kconfig"'
grep -q 'kernelsu' drivers/Makefile || die "drivers/Makefile 挂载失败"
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || die "drivers/Kconfig 挂载失败"
echo "[+] SukiSU 挂载完成"

# ---------------------------------------------------------------------------
if [ "$ENABLE_BBG" = "true" ]; then
  log "2/4 集成 Baseband Guard（BBG 基带保护）"
  rm -rf Baseband-guard
  # 必须完整克隆（BBG Makefile 遇到 .git/shallow 会执行 git fetch --unshallow）
  git clone "$BBG_REPO" Baseband-guard
  if [ -n "$BBG_SHA" ] && git -C Baseband-guard cat-file -e "${BBG_SHA}^{commit}" 2>/dev/null; then
    git -C Baseband-guard checkout -q --force "$BBG_SHA"
  fi
  git -C Baseband-guard log -1 --format='[=] BBG: %H  %ci  %s'

  ln -sfn ../Baseband-guard security/baseband-guard
  [ -e security/baseband-guard/Kconfig ] || die "security/baseband-guard 软链接无效"

  grep -q 'baseband-guard' security/Makefile || printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> security/Makefile
  insert_before_last_endmenu security/Kconfig 'source "security/baseband-guard/Kconfig"'
  grep -q 'baseband-guard' security/Makefile || die "security/Makefile 挂载失败"
  grep -q 'security/baseband-guard/Kconfig' security/Kconfig || die "security/Kconfig 挂载失败"

  # 5.10 具备现代 LSM 框架（DEFINE_LSM），BBG 走标准 LSM blob，无需 SELinux 补丁
  if grep -q '#define DEFINE_LSM(lsm)' include/linux/lsm_hooks.h; then
    echo "[=] 检测到 DEFINE_LSM：BBG 使用标准 LSM 基础设施（无需 SELinux 补丁）"
  else
    die "未检测到 DEFINE_LSM，该内核需要 BBG 的 SELinux 兼容补丁，请人工处理"
  fi
  echo "[+] BBG 挂载完成"
else
  log "2/4 跳过 BBG（ENABLE_BBG=false）"
fi

# ---------------------------------------------------------------------------
if [ "$ENABLE_SUSFS" = "true" ]; then
  log "3/4 集成 SUSFS（$SUSFS_BRANCH）"
  rm -rf susfs4ksu
  git clone --depth 1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
  git -C susfs4ksu log -1 --format='[=] susfs4ksu: %H  %ci  %s'

  PATCH_FILE="$(find susfs4ksu/kernel_patches -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n 1)"
  [ -n "$PATCH_FILE" ] || die "找不到 susfs 内核补丁（kernel_patches/50_add_susfs_in_*.patch）"
  echo "[=] 使用补丁：$PATCH_FILE"

  cp -r susfs4ksu/kernel_patches/fs/. fs/
  cp -r susfs4ksu/kernel_patches/include/. include/
  [ -f fs/susfs.c ] || die "fs/susfs.c 拷贝失败"
  [ -f include/linux/susfs.h ] || die "include/linux/susfs.h 拷贝失败"

  # 主补丁：本树 fs/notify/fdinfo.c 有 1 个 hunk 因上游针对较新 ACK 编写而失败
  # （上游打印 ignored_mask:0 并用 inotify_mark_user_mask()，我们 5.10.81 树是旧写法）。
  # 该 hunk 由 patches/susfs-fdinfo-fixup.patch 用本树的真实上下文补齐。
  patch -p1 --forward --no-backup-if-mismatch < "$PATCH_FILE" > /tmp/susfs-main.log 2>&1 || true
  grep -E 'FAILED|Reversed|malformed|can.t find file' /tmp/susfs-main.log | sed 's/^/      /' || true

  FIXUP="$WS/patches/susfs-fdinfo-fixup.patch"
  if [ -f "$FIXUP" ]; then
    if patch -p1 --forward --no-backup-if-mismatch < "$FIXUP"; then
      echo "[+] fdinfo.c 上下文适配补丁已应用"
    else
      die "susfs 的 fdinfo.c 适配补丁应用失败（上游补丁结构可能已变）"
    fi
  fi

  # 判定标准：除已被适配补丁覆盖的 fdinfo.c 外，不允许任何未解决的 hunk
  UNRESOLVED="$(find . -name '*.rej' -not -path './.git/*' | grep -v '^\./fs/notify/fdinfo\.c\.rej$' || true)"
  if [ -n "$UNRESOLVED" ]; then
    echo "$UNRESOLVED" | sed 's/^/      /'
    die "SUSFS 补丁存在未应用的 hunk，需要人工 rebase（见上方 FAILED 列表）"
  fi
  find . -name '*.rej' -not -path './.git/*' -delete
  find . -name '*.orig' -not -path './.git/*' -delete
  echo "[+] susfs 内核侧补丁完成（含 1 处已适配的上下文差异）"

  KSU_PATCH="susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
  if [ -f "$KSU_PATCH" ]; then
    ( cd KernelSU && patch -p1 --forward --no-backup-if-mismatch < "../$KSU_PATCH" ) \
      || die "SUSFS 的 KernelSU 侧补丁应用失败"
    echo "[+] KernelSU 侧 susfs 补丁已应用"
  fi
else
  log "3/4 跳过 SUSFS（ENABLE_SUSFS=false）"
fi

# ---------------------------------------------------------------------------
log "4/4 集成结果自检"
for f in drivers/kernelsu/Kconfig drivers/kernelsu/Makefile; do
  [ -e "$f" ] || die "缺少 $f"
done
echo "[=] drivers/Makefile:      $(grep -n 'kernelsu' drivers/Makefile | tr '\n' ' ' || true)"
echo "[=] drivers/Kconfig:       $(grep -n 'kernelsu' drivers/Kconfig | tr '\n' ' ' || true)"
if [ "$ENABLE_BBG" = "true" ]; then
  echo "[=] security/Makefile:     $(grep -n 'baseband-guard' security/Makefile | tr '\n' ' ' || true)"
  echo "[=] security/Kconfig:      $(grep -n 'baseband-guard' security/Kconfig | tr '\n' ' ' || true)"
fi
echo "[+] 全部集成完成"
