# patches/ — 针对小米 mondrian-s-oss 源码的适配补丁

## susfs-fdinfo-fixup.patch

**用途**：补齐 `susfs4ksu` 的 `50_add_susfs_in_gki-android12-5.10.patch` 在本内核树上无法应用的那 **1 个 hunk**。

### 背景（实测得出，非推测）

在真实源码上做过补丁试运行，结果是 **24 个文件里 23 个干净应用**，只有
`fs/notify/fdinfo.c` 的第 4 个 hunk 失败。

失败原因不是"改动冲突"，而是**上游补丁针对的 ACK 版本比我们新**：

| | 上游 susfs 补丁的上下文 | 本树（Linux 5.10.81）的实际代码 |
|---|---|---|
| fdinfo 打印格式 | `ignored_mask:0 ` | `ignored_mask:%x ` + `mark->ignored_mask` |
| mask 取值 | `inotify_mark_user_mask(mark)` | `mark->mask & IN_ALL_EVENTS` |

`inotify_mark_user_mask()` 这个函数**在本内核树里根本不存在**（已全树检索确认），
所以那段插入代码不能原样搬过来。

### 本补丁做了什么

1. 保留上游插入的整段 susfs 逻辑（SUS_KSTAT / SUS_MOUNT 两个分支的早退打印）
2. 把其中 2 处（两个分支各一处）改成使用本树已有的 API：
   ```c
   -  "… ignored_mask:0 ",  inode_mark->wd, ino, dev, inotify_mark_user_mask(mark));
   +  "… ignored_mask:%x ", inode_mark->wd, ino, dev, mark->mask & IN_ALL_EVENTS, mark->ignored_mask);
   ```
3. 用本文件的真实上下文（`/* IN_ALL_EVENTS … */` 注释块）作为 hunk 尾部上下文

### 验证情况

- ✅ 在本树抽取出的真实源码上 `patch -p1 --forward` 干净应用（exit 0）
- ✅ 应用后 `fdinfo.c` 含 susfs 代码，且不存在 `inotify_mark_user_mask` 残留
- ✅ 无其它未解决 hunk
- ⚠️ **未在真机上验证运行行为**。susfs 默认关闭，需要时再用 workflow 的
  `enable_susfs` 打开；若异常，关掉该开关即可回到干净构建。

### 上游补丁更新后怎么办

如果 `susfs4ksu` 更新了 5.10 分支、`fdinfo.c` 那个 hunk 本身修好了，
本补丁会因为找不到目标上下文而应用失败。届时删掉本文件即可
（`scripts/integrate.sh` 会因适配补丁失败而明确报错，不会静默产出半成品）。

---

## susfs 现状（实测结论，2026-09）

**结论：susfs 目前无法启用，默认关闭。启用会快速失败并给出明确提示。**

已经查清的三件事：

### 1. SukiSU 的 `susfs_new` 分支不是"内核带 susfs 的分支"

拉取该分支的文件树后发现，susfs 相关文件**全部在管理器 App 端**：

```
manager/app/src/main/java/com/sukisu/ultra/ui/screen/susfs/...   ← 只有 Kotlin UI
kernel/                                                          ← 无任何 susfs 文件
```

它的 `kernel/Kconfig` 里也**没有** `CONFIG_KSU_SUSFS`。所以"开 susfs 就换这个分支"是行不通的，
`integrate.sh` 已去掉这个自动切换。

### 2. 内核侧补丁可用

`50_add_susfs_in_gki-android12-5.10.patch`：24 个文件中 23 个干净应用，
仅 `fs/notify/fdinfo.c` 1 个 hunk 需要适配（已由本目录的 `susfs-fdinfo-fixup.patch` 解决，实测通过）。

### 3. KernelSU 侧补丁需要人工移植（这是真正的拦路石）

`kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`（3091 行 / 28 个文件）在 SukiSU 当前 `main` 上：

| 结果 | 数量 |
|---|---|
| 干净应用的 hunk | 25 |
| 带 fuzz 成功 | 2 |
| **失败** | **3 —— 全部集中在 `kernel/core/init.c`** |

失败的不是上下文偏移，而是**补丁面向重构前的老版 KernelSU**：它要大段删除/重排
`kernelsu_init()` 与 `kernelsu_exit()`（`ksu_syscall_hook_manager_init`、`ksu_late_loaded`
分支、`ksu_init_symbol_resolver()` 等），而 SukiSU 的 `init.c` 已经重写过（250 行，
初始化顺序完全不同）。这属于**移植**，不是补丁适配。

`CONFIG_KSU_SUSFS` 系列配置项正是由这个补丁加到 `kernel/Kconfig` 里的
（所以两个分支原本都没有它）。

### 想启用 susfs 需要做什么

1. 以 `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch` 为参考，
   把 `susfs_init()` 等调用按 **SukiSU 当前的** `kernelsu_init()` 顺序手工插入
2. 补丁对其余 27 个文件的改动可以照用（`patch -p1 --forward` 即可）
3. 完成后把结果做成 `patches/01-...patch`，`integrate.sh` 会按序自动应用

`integrate.sh` 在启用 susfs 时会先对 KernelSU 侧补丁做 dry-run，
不通过就立刻停下并打印以上结论，**不会浪费一次 25 分钟的编译**。

