# 红米 K60 (mondrian) 自定义内核 · GitHub 云编译

给 **红米 K60 / POCO F5 Pro（codename `mondrian`，骁龙 8+ Gen 1 / SM8475）** 编译一个集成
**SukiSU Ultra + KPM + Baseband Guard(BBG) + 网络驱动补齐** 的内核，全程用 **GitHub Actions 云编译**，
本地不需要 Linux 环境。

工具链：**LLVM（AOSP clang-r416183b）+ GCC（aarch64-linux-gnu / arm-linux-gnueabi）**

---

## 一、这套方案做了什么

| 项目 | 实现方式 | 说明 |
|---|---|---|
| **SukiSU Ultra** | `drivers/kernelsu` 挂载 + `CONFIG_KSU=y` | 走 **kprobe 钩子**（GKI 官方推荐），**不改一行内核源码** |
| **KPM** | `CONFIG_KPM=y` | SukiSU 内置的 KernelPatch Module 运行时模块支持 |
| **BBG 基带保护** | `security/baseband-guard` + `CONFIG_BBG=y` | LSM 实现，阻止恶意程序格式化基带/关键分区 |
| **SUSFS**（可选，默认关） | susfs4ksu `gki-android12-5.10` 补丁 | 隐藏增强，开启后自动切到 SukiSU `susfs_new` 分支 |
| **网络驱动补齐** | `configs/k60-extras.config` | BBR 拥塞控制、CAKE、ipset/netfilter 扩展、USB 无线网卡 |
| **刷机包** | AnyKernel3 | `split_boot + flash_boot`，只替换 boot.img 内核，不动 ramdisk |

### 内核源码基线

- 仓库：`MiCode/Xiaomi_Kernel_OpenSource`
- 分支：`mondrian-s-oss`
- 固定提交：`989b27aa8391a2ede9b067b53877c4c3343955fe`
- 版本：**Linux 5.10.81**，ACK `android12-5.10`，KMI generation **9**
- 结构：GKI + 小米 vendor 片段合并布局（`gki_defconfig` + `vendor/mondrian_GKI.config`）

---

## 二、三个必须知道的技术前提（决定了方案为什么这样设计）

这三条都是我直接读源码验证过的，不是猜的：

### 1. 必须用旧版 clang（clang-r416183b），不能用新版

基线 `gki_defconfig` 同时开了 `CONFIG_LTO_CLANG_FULL=y` 和 `CONFIG_CFI_CLANG=y`。
5.10 用的是**旧版 CFI**（`-fsanitize=cfi`），该选项在 **clang 16+ 已被移除**，换新版 clang 直接编译失败。
所以 `scripts/toolchain.sh` 锁定 AOSP 官方配套版本 `clang-r416183b`（= clang 12）。

### 2. 厂商预编译模块能被加载，靠的是 vermagic 里的 flag 段

`kernel/module.c` 里的实现：

```c
/* First part is kernel version, which we ignore if module has crcs. */
static inline int same_magic(const char *amagic, const char *bmagic, bool has_crcs)
{
        if (has_crcs) {
                amagic += strcspn(amagic, " ");   /* 跳过内核版本号 */
                bmagic += strcspn(bmagic, " ");
        }
        return strcmp(amagic, bmagic) == 0;
}
```

意思就是：**模块带 CRC（`CONFIG_MODVERSIONS=y`）时，内核加载模块不看版本号**，只比较
`SMP preempt mod_unload modversions aarch64` 这一串。

所以：
- 用 5.10.81 源码编译的内核，**可以正常加载你手机 HyperOS 里较新版本的厂商模块**（Wi-Fi/蓝牙/触控/音频）；
- 但 **`CONFIG_MODVERSIONS` / `CONFIG_MODULE_UNLOAD` / `CONFIG_PREEMPT` 这三项绝对不能改**，
  改任何一项 → flag 段不匹配 → 所有厂商模块拒绝加载。
- `scripts/configure.sh` 里有配置闸门，会强制校验这三项。

### 3. USB 无线网卡驱动只能编成模块（=m），不能内建

`modules.list.msm.mondrian` 里明确列出了厂商预编译模块：

```
cfg80211.ko
mac80211.ko
```

这两个在 `vendor_dlkm` 分区，由 init 在开机时加载。如果把 `CONFIG_CFG80211` 改成 `=y`（内建），
系统再去 insmod 原厂 `cfg80211.ko` 就会符号冲突 —— **原厂 Wi-Fi 直接全废**。

所以本项目所有 USB 无线网卡驱动一律 `=m`，编出来的 `.ko` 随包附带、需要手动 `insmod`。

---

## 三、目录结构

```
.
├── .github/workflows/build-kernel.yml   # 云编译主流程
├── configs/
│   ├── k60-sukisu-bbg.config            # SukiSU + KPM + BBG 配置片段
│   ├── k60-extras.config                # 网络驱动补齐片段
│   └── k60-susfs.config                 # SUSFS 配置片段（可选）
├── scripts/
│   ├── toolchain.sh                     # 下载 clang-r416183b（含 GitHub 镜像回退）
│   ├── clone-kernel.sh                  # 克隆小米官方源码并检出固定提交
│   ├── integrate.sh                     # 集成 SukiSU / BBG / SUSFS
│   ├── configure.sh                     # 生成 .config + 配置闸门校验
│   ├── build.sh                         # 编译内核 + 驱动模块
│   ├── build-88xxau.sh                  # 【可选】外置 88XXAU 驱动
│   └── pack.sh                          # 打包 AnyKernel3
├── anykernel/anykernel.sh               # AnyKernel3 配置（mondrian 设备校验）
└── docs/刷机与回滚.md                    # 刷机 / 回滚详细步骤
```

---

## 四、怎么用

### 1. 推送到 GitHub

```bash
git init
git add .
git commit -m "Redmi K60 kernel: SukiSU + KPM + BBG + net drivers"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 仓库建议设为 **Private**（无所谓，只是习惯）。推送后 Actions 会自动跑一次默认配置的编译。

### 2. 触发编译

到仓库 **Actions → 编译红米K60内核 (SukiSU+KPM+BBG) → Run workflow**，按需勾选参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `ksu_ref` | `v4.2.0` | SukiSU 版本，可填 tag / 分支 / 提交 |
| `enable_kpm` | ✅ | KPM 模块支持 |
| `enable_bbg` | ✅ | 基带保护 |
| `enable_susfs` | ❌ | 开启后**自动切到 `susfs_new` 分支**并打 susfs 补丁 |
| `enable_usb_wifi` | ✅ | USB 无线网卡驱动（8188EU / 8XXXU / RT2800 / ATH9K_HTC / MT7601U） |
| `enable_88xxau` | ❌ | 额外编外置 RTL8812AU/8821AU，失败不影响主产物 |
| `lto` | `thin` | `thin` 快、`full` 与官方一致、`none` 关 LTO+CFI |
| `debug_info` | ❌ | 保留调试信息（体积 +十几 GB，CI 建议关） |
| `release_tag` | 空 | 填了就直接发 Release，例如 `v1.0-k60` |

### 3. 下载产物

- **`K60-AnyKernel3`** ← 刷机包（**主角**）
- `K60-extra-modules` ← 额外驱动 `.ko`（USB 无线网卡）
- `K60-Image-lz4` ← 裸内核镜像（自己打包时用）

刷机步骤见 [`docs/刷机与回滚.md`](docs/刷机与回滚.md)。

---

## 五、编译一次要多久

- ThinLTO（默认）：约 **50–80 分钟**（4 核 runner）
- FullLTO：约 **90–150 分钟**
- 有 ccache 缓存命中时后续构建会快很多

Actions 单任务上限 6 小时，`timeout-minutes: 350` 留了余量。

---

## 六、USB 无线网卡怎么用

驱动是 `=m` 模块，**不会自动加载**（Android 的 `modules.load` 里没有它们）。刷完内核后：

```bash
# 把 K60-extra-modules 解压到手机，例如 /data/local/tmp/
su -c 'insmod /data/local/tmp/r8188eu.ko'
su -c 'insmod /data/local/tmp/rtl8xxxu.ko'
su -c 'insmod /data/local/tmp/rt2800usb.ko'
su -c 'insmod /data/local/tmp/ath9k_htc.ko'
su -c 'insmod /data/local/tmp/mt7601u.ko'
```

想开机自动加载，可以放到 KernelSU 模块的 `post-fs-data.sh` 里。

插上 USB 网卡后用 `dmesg | tail` 或 `ip link` 看是否识别。

---

## 七、已知限制

1. **首次编译不保证一次成功**。LTO + CFI + 第三方补丁组合，常见失败点是补丁 fuzz、
   配置依赖被静默丢弃。`configure.sh` 的闸门和分支的日志已经把排查点标出来了；
   哪一步失败直接把日志贴出来即可定位。
2. **建议先刷一次官方原厂 `boot.img` 备份**（见刷机文档），随时可回滚。
3. **SUSFS 默认关闭**。它是侵入性最大的补丁（改 `fs/`、`mm/`、`security/selinux/` 共 24 个文件），
   先让主流程跑通、确认开机能用，再决定是否开启。
4. **不做 KMI 符号裁剪**：`android/abi_gki_aarch64*.xml` 一个字节都没动，
   保证厂商模块的符号 CRC 不变。
5. 本项目**不修改任何设备树（DTS）**，DTB 仍用你 ROM 里的原厂文件。

---

## 八、致谢

- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) —— 内核级 root 与 KPM
- [Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) —— 基带保护 LSM
- [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) —— SUSFS
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— 刷机包模板
- [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) —— 官方内核源码
