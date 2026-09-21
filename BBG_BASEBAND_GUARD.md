# BBG 内核级基带保护 — 已实现

## 结论

用户要求「bbg 内核级保护基带」。**该项已实际集成**，不是 TODO。

> 历史说明：用户最初写作「bbc 内核级保护分区」，经确认为笔误，实为
> **bbg = Baseband Guard（基带保护）**。本文件早前的「未实现」版本是基于
> 「bbc」这个查不到的名字写的，现已按真实的 bbg 重写。

- **上游项目**：[vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)
- **许可证**：GPL-2.0
- **内核开关**：`CONFIG_BBG=y`
- **集成位置**：`security/baseband-guard/`
- **集成方式**：`scripts/integrate-bbg.sh`（复刻上游 `setup.sh`，但不依赖 git）

## 它到底做了什么（读源码得出，非猜测）

BBG 是一个 **LSM（Linux Security Module）**，在写路径上拦截对受保护块设备的写入。

**默认拒绝（default-deny）** —— 这是关键。`baseband_guard.h` 里维护的是一份
**允许写入的白名单**，不在名单上的分区一律保护：

```c
static const char * const allowlist_names[] = {
    "boot", "init_boot", "vendor_boot", "vendor_kernel_boot",   // 可被 CONFIG_BBG_BLOCK_BOOT 移除
    "dtbo",
    "userdata", "cache", "metadata", "misc",
    "vbmeta", "vbmeta_system", "vbmeta_vendor",
    "recovery"                                                   // 可被 CONFIG_BBG_BLOCK_RECOVERY 移除
};
```

因此 **`modem`、`fsg`、`persist`、`abl`、`xbl`、`modemst1/2`、`fsc` 等基带与引导链分区
天然处于保护状态** —— 这正是「保护基带」的实质。

### 挂的钩子

| LSM hook | 作用 |
|---|---|
| `file_permission` | 拦截对块设备的 `MAY_WRITE` 打开/写权限 |
| `inode_setattr` | 拦截对块设备的属性修改 |
| `file_ioctl` | 拦截破坏性 ioctl：`BLKDISCARD`、`BLKSECDISCARD`、`BLKZEROOUT`、`BLKPG`、`BLKRRPART` 等 |

被拒绝时返回 `-EPERM`，并打印 `pr_info` 日志（含 dev、路径、pid、comm、argv），便于追溯。

### 信任模型（比想象中更有针对性）

`current_process_trusted()` 不是简单的 uid 判断。`tracing/tracing.c` 的
`bb_bprm_set_creds` 会在 execve 时检查 SELinux 域：

- 域为 `u:r:su:s0` / `u:r:ksu:s0` / `u:r:magisk:s0` → 标记为 **untrusted**
- trusted 进程直接放行；untrusted 进程才走白名单校验

也就是说：**这套机制专门用来阻止「已经拿到 root 的进程」去动基带分区**，
而不是阻止普通 App。这与 SukiSU 是互补关系，不是冲突关系。

### 白名单缓存

`allowed_devs` 是一个哈希表缓存：首次命中白名单分区后按 `dev_t` 缓存，后续走快速路径。
另对 `zram` 设备直接放行。

## 集成做了什么（3 步，等价于上游 setup.sh）

1. 源码放入 `security/baseband-guard/`（14 个文件）
2. `security/Makefile` 追加 `obj-$(CONFIG_BBG) += baseband-guard/`
3. `security/Kconfig` 在**最后一个 `endmenu` 之前**插入
   `source "security/baseband-guard/Kconfig"`

### 5.10 特有：不需要 SELinux 补丁

上游 `setup.sh` 对老内核会打 `sepatch.txt`（改 `security/selinux/Makefile` 与
`objsec.h`，给 `task_security_struct` 加 `bbg_cred` 字段）。判据是
`include/linux/lsm_hooks.h` 里有没有 `#define DEFINE_LSM(lsm)`。

本内核树（5.10）**有** `DEFINE_LSM`（已核实，在 `include/linux/lsm_hooks.h:1621`），
所以走「现代 LSM blob」路径：BBG 自带 `bbg_blob_sizes`，补丁被**正确跳过**。
`integrate-bbg.sh` 会检查这一点，若 `DEFINE_LSM` 缺失会直接报错退出，
而不是悄悄产出一份坏配置。

## ⚠ 一个必须设置的隐藏依赖：CONFIG_LSM

BBG 的 `Makefile` 里有一道**硬性构建闸门**：

```make
ifneq ($(findstring baseband_guard,$(CONFIG_LSM)),baseband_guard)
  $(error Please follow Baseband-guard's README.md, to correct integrate)
endif
```

**只要 `DEFINE_LSM` 存在且 `CONFIG_LSM` 里没有 `baseband_guard`，构建会直接失败。**

而 `gki_defconfig` **根本没有设置 `CONFIG_LSM`**，其有效值来自 `security/Kconfig` 的
默认项（已核实）：

```
"lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"
```

所以 `configs/k60-sukisu-kpm.fragment` 里显式设置了：

```
CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,baseband_guard,smack,tomoyo,apparmor,bpf"
```

**为什么不用上游建议的 sed 方案**：上游 README 给的
`sed -i '/^config LSM$/,/^help$/{...}' security/Kconfig` 会破坏
`config LSM` 段的全部 `default` 行，上游自己也标注了
「**警告** 此方法会导致执行 setup.sh --cleanup 时出现 LSM Kconfig 配置中 default 全部被删除的问题」。
写进 defconfig 更干净、可复现、可回滚。

## 可选加固（默认关闭）

| 开关 | 效果 | 为何默认关闭 |
|---|---|---|
| `CONFIG_BBG_BLOCK_BOOT` | 把 `boot`/`init_boot`/`vendor_boot` 移出白名单 | 会导致**无法在系统内刷内核**，只能进 recovery/fastboot |
| `CONFIG_BBG_BLOCK_RECOVERY` | 把 `recovery` 移出白名单 | 会导致无法在系统内刷 recovery |

上游默认即为 `n`。需要更强保护可在 fragment 里打开，但请清楚代价。

## 验证方式（刷机后）

```bash
# 1. 确认 BBG 已加载并打印版本
dmesg | grep -i baseband_guard
#    期望看到 "baseband_guard: version: ..." 与 "repo: ..."

# 2. 确认 LSM 列表包含 baseband_guard
cat /sys/kernel/security/lsm
#    期望输出含 baseband_guard

# 3. 实际触发一次拦截（⚠ 不要拿 modem 试！用可接受失败的分区）
su -c 'dd if=/dev/zero of=/dev/block/by-name/persist bs=4096 count=1'
#    期望：Operation not permitted，且 dmesg 出现
#    "baseband_guard: deny write to protected partition ..."
```

## 已知遗留 / 未验证

1. **尚未实际编译和开机验证。** 本仓库的准备环境（Windows 10 1809 LTSC）
   无法承载 Linux 内核构建，首次 CI 运行才是真正的检验。
2. BBG 硬编码了 `su`/`ksu`/`magisk` 三种 SELinux 域来识别 root 进程；
   mondrian 真机上的域命名是否完全匹配需要确认。
3. 与 SukiSU 叠加后在逻辑上互补，但**同时开启后「用 root 刷基带」会被 BBG 拦下** ——
   这是预期行为。如需临时放行，须在 recovery/fastboot 下操作。

---

## 附：源码级兼容性审计（针对本内核 5.10.81）

在无编译环境的前提下，逐项核对了 BBG 与 SukiSU 依赖的内核 API。结论：**未发现阻塞性不兼容**。

### BBG 侧

| 检查项 | 结果 | 依据 |
|---|---|---|
| `DEFINE_LSM` 存在（决定走现代 LSM blob 路径、跳过 SELinux 补丁） | 存在 | `include/linux/lsm_hooks.h:1621` |
| `security_add_hooks` 分支 | 5.10 走 `#elif >= 4.11` 分支，传字符串 `"baseband_guard"` | `kernel_compat.h:101-109` |
| `bbg_is_named_device` 分支 | 5.10 < 5.11 -> 用 `blkdev_get_by_dev` 旧路径 | `kernel_compat.h:41-63` |
| `is_allowed_partition_dev_resolve` 分支 | 5.10 未定义 `BBG_COMPAT_HAS_BLOCK_DEVICE_API`（因 `genhd.h` 有 `disk_get_part`）-> 走 `hd_struct`/`part->info` 旧路径 | `blkdev_helper.c:88-168` |
| `BB_HAS_IOCTL_COMPAT` | 未定义（`lsm_hook_defs.h` 无 `file_ioctl_compat`）-> 自动省掉该 hook | 已核实 |
| `objsec.h` / `block/blk.h` 包含路径 | Makefile 注入 `-I$(srctree)/security/selinux` 与 `-I$(srctree)/block`，二者均存在 | 已核实 |
| `bbg_cred()` 取 cred blob | 5.10 用 `cred->security + bbg_blob_sizes.lbs_cred` | `tracing/tracing.h` |

### SukiSU 侧

| 检查项 | 结果 |
|---|---|
| `security_add_hooks` / `lsm_blob_sizes` / `get_cmdline` / `register_kprobe` | 均存在 |
| `kallsyms_lookup_name` | 存在（5.10 仍导出，KPM 的符号解析依赖它） |
| `struct proc_ops` | 存在 -> 定义 `KSU_COMPAT_HAS_PROC_OPS`，走新路径 |
| `set_fs()` | 5.10 仍存在，不会提前触发移除相关编译错误 |
| `__flush_dcache_area` | 存在于 `arch/arm64/include/asm/cacheflush.h:66` -> `KSU_NEW_DCACHE_FLUSH` 探测通过，`patch_memory.c` 走该分支 |
| KPM 构建方式 | `obj-$(CONFIG_KPM) += kpm/*.o`，内建编译（非外部模块） |

### 一处曾被我误判、现已澄清的地方（记录以免重犯）

SukiSU 的 `Kbuild` 里有：

```make
ifdef KBUILD_EXTMOD
ifeq ($(CONFIG_KSU_DISABLE_MANAGER),y)
ccflags-y += -DCONFIG_KSU_DISABLE_MANAGER=1
endif
...
endif
```

我最初只看到 grep 出的片段，误以为这是**无条件**禁用管理器与策略。
实际上它被 `ifdef KBUILD_EXTMOD` 包裹（第 58-71 行），**只对 `M=` 外部模块编译生效**。
本项目是内建编译（`obj-$(CONFIG_KSU) += kernelsu.o`），因此 Kconfig 正常生效，
`CONFIG_KSU_DISABLE_MANAGER` / `_POLICY` 保持默认 `n`，
`manager/apk_sign.o` 等文件照常编入（见 `Kbuild:26-30`）。

### `KSU_VERSION` 的一个已知坑（低风险，记录备用）

`Kbuild:104-126` 会联网推导版本号：

```
KSU_VERSION = 40000 + LOCAL_COUNT - 2815     # LOCAL_COUNT 来自 GitHub API
```

若 `curl api.github.com` 不可达，`LOCAL_COUNT` 为空 -> **兜底为硬编码 `13000`**。
该值经 `supercall/dispatch.c:833` 与 `ksu.h:8` 上报给管理器，
因此只影响「管理器显示的版本号」，不影响功能。
若将来在无网环境编译时看到 13000，说明用了兜底值，不要误以为源码是旧版。
GitHub Actions 有网络，正常不会触发。
