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
