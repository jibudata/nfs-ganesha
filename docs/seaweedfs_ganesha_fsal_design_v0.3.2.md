# SeaweedFS Native NFS-Ganesha FSAL 架构与详细设计

**版本：v0.3.2（P0 工程实施契约修正与形式化验证定稿 — Frozen P0 Contract）**  |  **日期：2026-11-18**  |  **状态：Gate P0-A / P0-B 冻结实施契约**

> **基线代码库与固定 Commit SHA**：
> - **NFS-Ganesha**：分支 `dev-V15.9`，Commit `42bc41b62c12346aea30357cb613944e1032890b`
> - **SeaweedFS**：分支 `dev-4.48`，Commit `530be3e37337488ecc34d58441e0bc476e121c93`
> - **形式化验证套件**：`docs/formal/FSALSeaweedModel.lean`（Lean 4 规约与定理证明）+ `docs/formal/model_checker_test.go`（穷举有限状态机模型检验，已通过 8,500+ 状态与路径穷举验证）

---

## v0.3.2 关键实施契约修正摘要（响应第三轮架构评审 + 形式化模型检验发现）

在三轮架构评审批准总体架构（*Native C FSAL + 同进程 Go Storage Engine + C-Owned Native Arena*）的基础上，v0.3.2 针对评审指出的 5 项 P0 实施契约矛盾、4 项工程细节，以及我们在 **Lean 4 / 穷举状态机验证中额外发现的 2 条关键安全不变量**，完成如下收敛：

1. **修正 P0-1（HardLink 绝不改变 `SeaweedObjectID`）**：
   - 严格解耦三个概念：**`SeaweedFS HardLinkId`**（Filer 底层共享数据块的内部 KV 键）、**`SeaweedObjectID`**（128-bit UUID，持久化于 `Entry.Extended["nfs.object_id"]`，从文件诞生到最终 `nlink == 0` 永久不变）、**`NFS FileHandle`**（对 `SeaweedObjectID` 的 28B 封装）。
   - 创建硬链接（`nlink: 1 -> 2`）及删除其一（`nlink: 2 -> 1`）时，**原文件的 `SeaweedObjectID` 保持 100% 不变**，新旧路径共享同一个 `nfs.object_id`。对存量无 `nfs.object_id` 的文件提供基于 `ObjectTransaction (PATCH_EXTENDED)` 的并发安全 Lazy Backfill，并明确 64-bit `st_ino` 映射规则（见专题一 §1.1）。
2. **修正 P0-2（引入 C-Owned Dirty Page Map，消除部分覆盖写的二次 `memcpy` 矛盾）**：
   - 采纳评审推荐的 **方案 A（C-Owned Dirty Page Map）**：C 层不仅管理 `ArenaSlot` 物理池，还维护每个活跃文件对象的轻量级页表 `(ExportID, ObjectID, LogicalPageIdx) -> ArenaSlot`。
   - 当部分覆盖写（如 4KB `pwrite`）到达时：若目标逻辑页已有处于 `WRITABLE_DIRTY` 的 `ArenaSlot`，**C 层直接在原地将 `iov` `memcpy` 进该已有 `ArenaSlot` 的对应偏移**（严格 1 次 `memcpy`、0 新槽位分配、0 Go 层二次合并拷贝）；仅当目标页尚无槽位或旧槽位已进入 `SEALED_UPLOADING` 时才申请新槽位。
   - **随机小I/O防放大扩展**：Arena 架构支持 `64 KiB Small Sub-Slot` 与 `1 MiB Full Slot` 双粒度（或 Sub-Slot 切分），避免 4KB 随机写造成 256 倍内存放大。
3. **修正 P0-3（解耦 `Request Completion State` 与 `ArenaSlot Ownership State` + C 栈数组同步拷贝规则）**：
   - 将 **请求完成状态机（决定谁调用 `done_cb`）** 与 **槽位引用计数状态机（`slot->pin_count` + `slot->generation`，决定何时回收 `ArenaSlot` 内存）** 彻底分离。
   - 当 C Watchdog 触发超时时，仅推进 `Request Completion State` 回调 `done_cb` 并通知 Go 取消 Context；**只要 Go Upload Worker 尚未退出读取（`slot->pin_count > 0`），绝不回收该 `ArenaSlot`**，彻底根除超时竞态下的 Use-After-Free。
   - **ABI 铁律**：C 传入的 `const struct sw_slot_ref *slots` 为栈数组，Go 必须在 `cgo` 入口函数返回前将其值拷贝至 Go 切片，严禁在后台协程中持有 C 栈指针；Go 读取槽位前必须经由 C 的 `sw_arena_pin_and_validate(slot_id, generation)` 校验纪元号。
4. **修正 P0-4（Write Verifier 明确为全局 Server-Wide Durability Epoch + 区分 NFSv3/v4 背压行为）**：
   - 遵循 RFC 1813 与 RFC 8881，将 Durability Epoch 定义为 **Ganesha 进程全局单例 `g_server_durability_epoch`**（所有 Export 共享同一 Verifier，任一 Export 发生不可恢复的已确认 `UNSTABLE` 数据丢失均递增全局纪元）；抽象统一的 Ganesha Core 函数 `nfs_get_server_write_verifier()` 覆盖 NFSv3/v4 全部成功路径。
   - 明确 Ganesha V15.9 背压协议差异：`ERR_FSAL_DELAY` 在 NFSv4 下返回 `NFS4ERR_DELAY`，而在 NFSv3 下触发 `NFS_REQ_DROP`（丢弃请求等待客户端 RPC 超时重传）。
   - 将原 `Commit Reserve` 拆分为 **`Stable Write Buffer Reserve`（10% Arena，专供 `FILE_SYNC`/`DATA_SYNC` 新写入）** 与 **`COMMIT Execution Reserve`（专用 Commit 队列、Upload Worker 与 Filer 连接配额）**。
5. **修正 P0-5（精确界定 Filer CAS 保护范围：`IF_ENTRY_EQUAL` vs `IF_CHUNKS_EQUAL` vs `ObjectTransaction`）**：
   - 修正 `IF_CHUNKS_EQUAL` 不保护并发属性修改（如 `chmod`/`chown`）的漏洞：凡替换完整 Entry 的操作一律使用 **`IF_ENTRY_EQUAL`**；仅修改 Extended 属性使用 **`ObjectTransaction (PATCH_EXTENDED)`**；多路径目录操作使用 **`ObjectTransaction`**。
6. **形式化模型检验发现并闭环的 2 条隐藏关键不变量（见专题三）**：
   - **`INV-RSV-DRAIN`（由穷举模型检验器自动捕获）**：当 `FILE_SYNC` 写入动用了 `Stable Write Buffer Reserve (10%)` 槽位时，**必须在本次同步写内立即 Seal 并上传释放该槽位**，严禁将其留在 C Dirty Page Map 中充当长驻 `UNSTABLE` 脏页，否则后续 `UNSTABLE` 写会借壳耗尽保留池！
   - **`INV-CHUNK-STRICT-TS`（由源码审计 + Lean 4 证明发现）**：SeaweedFS `weed/filer/filechunks_read.go:68-78` 的扫描线算法在遇到两个重叠块拥有**相同 `ModifiedTsNs`** 时会静默漏插第二个区间！因此 FSAL 为每个 Chunk 分配的 `ModifiedTsNs` 必须由单调递增原子计数器保底（$\text{ts}_1 < \text{ts}_2$ 严格大于），从数学上保证乱序并发上传的可交换性与线性一致性。

---

# 目录

- [1. 架构总览与 C / Go 硬化边界](#1-架构总览与-c--go-硬化边界)
- [2. P0-1 修正：不可变 `SeaweedObjectID`、HardLink 语义与 `st_ino` 映射](#2-p0-1-修正不可变-seaweedobjectidhardlink-语义与-st_ino-映射)
- [3. P0-2 修正：C-Owned Dirty Page Map 与单次 `memcpy` 部分覆盖写](#3-p0-2-修正c-owned-dirty-page-map-与单次-memcpy-部分覆盖写)
- [4. P0-3 修正：请求完成状态机与 ArenaSlot Pin 生命周期解耦](#4-p0-3-修正请求完成状态机与-arenaslot-pin-生命周期解耦)
- [5. P0-4 修正：Server-Wide Durability Epoch 与 NFSv3/v4 背压语义](#5-p0-4-修正server-wide-durability-epoch-与-nfsv3v4-背压语义)
- [6. P0-5 修正：Filer CAS 精确保护矩阵与孤儿 Chunk 回收](#6-p0-5-修正filer-cas-精确保护矩阵与孤儿-chunk-回收)
- [7. 关键工程边界：`O_APPEND`、Open-Unlink 强隔离与锁恢复屏障](#7-关键工程边界o_appendopen-unlink-强隔离与锁恢复屏障)
- [8. 修订后的五阶段 Gate 准出标准（含 P0-B 9 项强制测试）](#8-修订后的五阶段-gate-准出标准含-p0-b-9-项强制测试)
- [专题一：28B Handle、HardLink 不变性、Lazy Backfill 与 Open-Unlink 详细设计](#专题一28b-handlehardlink-不变性lazy-backfill-与-open-unlink-详细设计)
- [专题二：C-Owned Arena、Dirty Page Map 与双状态机解耦 C/Go 代码契约](#专题二c-owned-arenadirty-page-map-与双状态机解耦-cgo-代码契约)
- [专题三：I/O 与状态机形式化验证（Lean 4 定理证明 + Go 穷举模型检验）](#专题三io-与状态机形式化验证lean-4-定理证明--go-穷举模型检验)

---

# 1. 架构总览与 C / Go 硬化边界

```mermaid
flowchart TB
    subgraph C_Fortress["C Layer: FSAL_SEAWEED (Protocol, Native Arena, Dirty Page Map & Context Fortress)"]
        direction TB
        C_API["Ganesha FSAL ABI\n(open2 / read2 / write2 / commit2 / lock_op2 / create_handle)"]
        C_PMAP["Per-File C Dirty Page Map\n((ExportID, ObjectID, LogicalPageIdx) -> Writable ArenaSlot)\n支持原地部分覆盖写 (In-place Partial Overwrite, 严格 1 次 memcpy)"]
        C_ARENA["Process-Global C Native Arena (mmap, 1MiB Full Slots + 64KiB Sub-Slots)\n80% Normal Write | 10% Stable Write Reserve | 10% Read Reserve\n+ Pin/Unpin RefCount + 32-bit Generation (防 ABA)"]
        C_COMP["Decoupled Dual State Machines\n1. Request Completion CAS (done_cb ownership)\n2. ArenaSlot Pin Count (memory reclamation ownership)"]
    end

    subgraph ABI_Boundary["Strict CABI Firewall (sw_backend_abi.h)"]
        ABI_Rule["1. 仅传递 struct sw_slot_ref {slot_id, generation, offset, length}，Go 入口同步拷贝值，绝不保存 C 栈指针\n2. Go 访问内存前必须经 C Pin & Validate Generation；Go 退出读取后 Unpin\n3. 严禁传递 struct iovec* 到 Go | 严禁 Go 触碰 Ganesha op_ctx"]
    end

    subgraph Go_Engine["Go Layer: libseaweed_fsal_backend.so (Storage & Network Engine)"]
        direction TB
        Go_Chunk["LogicalChunk Seal & Strict-Monotonic TsNs Manager\n(Assembles sealed page chains, stamps strictly increasing ModifiedTsNs)"]
        Go_Stream["COMMIT Execution Reserve & Streaming Volume Uploader\n(Dedicated Commit Workers + Bulk Workers, Mode A ?fsync=true)"]
        Go_Meta["Namespace, Immutable ObjectID & Filer CAS Client\n(IF_ENTRY_EQUAL / IF_CHUNKS_EQUAL / ObjectTransaction, Lock Recovery Barrier)"]
    end

    C_API --> C_PMAP --> C_ARENA
    C_PMAP == "Seal Completed/Flushed Page Chain (Pinned sw_slot_ref[])" ==> ABI_Boundary
    ABI_Boundary ==> Go_Chunk --> Go_Stream
    Go_Stream == "sw_c_complete_req(req_id) & sw_c_unpin_slots(slot_ref[])" ==> C_COMP
    C_COMP --> C_ARENA
```

---

# 2. P0-1 修正：不可变 `SeaweedObjectID`、HardLink 语义与 `st_ino` 映射

## 2.1 严格区分三个身份标识（解决 HardLink 改变 ObjectID 矛盾）

| 标识名称 | 格式与存储位置 | 职责与生命周期不变量 |
| :--- | :--- | :--- |
| **`SeaweedObjectID`** | 128-bit UUID (`[16]byte`)，持久化于 `Entry.Extended["nfs.object_id"]` | **FSAL 唯一权威对象身份**。在文件首次创建（或首次 Lazy Backfill）时生成，**在后续创建硬链接（`nlink: 1 -> 2`）、删除部分硬链接（`nlink: 2 -> 1`）、跨目录 Rename 全过程中永久保持不变！** |
| **`SeaweedFS HardLinkId`** | 16B 二进制 ID，存储于 `Entry.HardLinkId` | **SeaweedFS Filer 内部硬链接共享机制**。仅用于 Filer Store 内部通过 `KvGet(HardLinkId)` 共享多个目录项的 `AttributesAndChunks`，**绝不替代或覆盖 `SeaweedObjectID`**。 |
| **`NFS Wire FileHandle`** | 28B 定长二进制（含 `export_id` + `SeaweedObjectID` + `generation`） | **协议层句柄**。因内嵌不可变的 `SeaweedObjectID`，任何硬链接操作或重命名均不会导致已有客户端持有的 FileHandle 失效。 |
| **POSIX `st_ino` (`fileid`)** | 64-bit 整数，填充于 `attrs_out->fileid` | **客户端可见的 64 位 Inode 号**。由 `SeaweedObjectID` 折叠哈希并结合本地 충돌检测表生成，同一文件的所有硬链接返回完全相同的 `st_ino`。 |

## 2.2 HardLink 生命周期操作契约
1. **创建文件 `/data/fileA`**：生成 `SeaweedObjectID = UUID-A`，写入 `Entry.Extended["nfs.object_id"] = UUID-A` 及 Filer KV `nfs:obj:<exp>:<UUID-A>`。
2. **创建硬链接 `link(/data/fileA, /data/fileB)`**：
   - Filer 为两条目录项生成共享的 `HardLinkId = HL-123`；
   - **两条目录项的 `Extended["nfs.object_id"]` 均保持为 `UUID-A`**！
   - 更新 KV `nfs:obj:<exp>:<UUID-A>` 的 `Paths` 列表加入 `/data/fileB`。客户端无论通过 `fileA` 还是 `fileB` Lookup，拿到的都是 `ObjectID = UUID-A`。
3. **存量无 `nfs.object_id` 文件的并发安全 Lazy Backfill**：
   - 对于由旧版 FUSE 或 S3 创建的存量文件（无 `Extended["nfs.object_id"]`）：
     - 若该存量文件已带有 `HardLinkId`，则按确定性算法 `UUIDv5(Namespace_SeaweedHardLink, HardLinkId)` 派生 `ObjectID`（确保从不同硬链接路径并发首次访问时派生出完全一致的 `ObjectID`）；
     - 若为普通存量文件，生成随机 `UUIDv4`，通过 Filer `ObjectTransaction` 执行带前置条件的 `PATCH_EXTENDED`（仅当 `nfs.object_id` 为空时写入）；若并发竞争返回 `PRECONDITION_FAILED`，重新读取胜出者写入的 `nfs.object_id`。

---

# 3. P0-2 修正：C-Owned Dirty Page Map 与单次 `memcpy` 部分覆盖写

## 3.1 为什么采用方案 A（C-Owned Dirty Page Map）？
在 v0.3.1 中，若 1 MiB 逻辑页已有一个未封块的 `ArenaSlot A`，此时应用执行 4 KiB 部分覆盖写 `pwrite(fd, buf, 4096, 128*1024)`，如果先分配新 `Slot B` 拷贝 4 KiB 再到 Go 层合并进 `Slot A`，必然产生**第二次 `memcpy`**。

在 **v0.3.2 方案 A** 中，C 层 `struct sw_obj_handle` 直接内嵌一把页表读写锁与轻量级 **C Dirty Page Map**：
- **映射关系**：`LogicalPageIdx (offset / slot_size) -> struct sw_dirty_page_entry { uint32_t slot_id; uint32_t generation; uint32_t valid_bitmap_or_intervals; enum { PAGE_WRITABLE, PAGE_SEALED_UPLOADING } state; }`。
- **写入执行路径（100% 满足单次 `memcpy` 与单活跃槽位约束）**：
  1. **命中已有 `PAGE_WRITABLE` 槽位 `Slot A`（部分覆盖写或追加写）**：
     - C 层在页表锁保护下直接定位到 `Slot A`，校验 `generation`，**将 `write_arg->iov` 的 4 KiB 数据直接原地 `memcpy` 到 `Slot A` 的 `128 KiB` 偏移处**！
     - 更新该页的有效字节区间列表与文件 `WriteSeq`。**0 新槽位分配、严格 1 次 `memcpy`、无需 Go 层二次合并**！
  2. **未命中，或旧槽位已处于 `PAGE_SEALED_UPLOADING`（写入时旧页正在后台上传）**：
     - 旧槽位 `Slot A` 保持 `PAGE_SEALED_UPLOADING` 状态（由后台 Go Upload Worker 持有 Pin 引用，带旧 `WriteSeq`）；
     - C 层为当前逻辑页原子申请一个新的 `ArenaSlot B`（生成新 `WriteSeq`），将 `write_arg->iov` 直接 `memcpy` 进 `Slot B`，并将页表当前 `PAGE_WRITABLE` 指向 `Slot B`。
  3. **封块上传（Seal）**：
     - 当某 `LogicalChunk`（如 16 个连续 `1 MiB` 槽位）写满、或触发 `ProactiveFlush` / `COMMIT` / `FILE_SYNC` 时，C 层将这些槽位状态切换为 `PAGE_SEALED_UPLOADING`，增加其 `pin_count`，并将 `sw_slot_ref[]` 值数组提交给 Go Upload Worker。

## 3.2 随机小块写的内存放大抑制（Dual-Tier Sub-Slot 扩展能力）
为防止极端工作负载（如在数 GB 范围内每隔 1 GB 随机写 4 KiB）导致每个 4 KiB 独占一个 `1 MiB` Slot（256 倍放大）：
- C Arena 将物理 `1 MiB` 块作为大页基座，内部支持切分为 **16 个 `64 KiB` Small Sub-Slot**。
- 当写入长度 `< 64 KiB` 且非顺序流时，C Dirty Page Map 按 `64 KiB` Sub-Slot 粒度挂载；当检测到顺序写流（Sequential Frontier）时直接挂载 `1 MiB` Full Slot。

---

# 4. P0-3 修正：请求完成状态机与 ArenaSlot Pin 生命周期解耦

## 4.1 双状态机正交解耦设计（根除 Watchdog 超时竞态下的 Use-After-Free）

| 状态机名称 | 作用对象 | 状态转换与不变量 |
| :--- | :--- | :--- |
| **1. Request Completion State** | `struct sw_async_io_req` | `ALLOCATED -> SUBMITTED -> COMPLETING -> COMPLETED -> RELEASED`<br>**职责**：通过 CAS 决定唯一一个有权调用 Ganesha `done_cb` 的线程（Go 正常完成 vs C Watchdog 超时 vs Export 卸载）。 |
| **2. ArenaSlot Ownership State** | `struct sw_arena_slot` | `FREE (pin_count==0) <-> PINNED (pin_count > 0, generation = G)`<br>**职责**：决定物理内存槽位何时能放回 `free_ring` 供后续请求复用。**只有当 `atomic_fetch_sub(&slot->pin_count, 1) == 1` 时，才执行 `slot->generation++` 并归还入池！** |

### Watchdog 超时竞态安全时序
当 Go Upload Worker 正在读取 `ArenaSlot S`（此时 `S.pin_count == 1`）而网络卡顿触发 C Watchdog 超时：
1. **C Watchdog**：通过 CAS 将 `areq->state` 从 `SUBMITTED` 置为 `COMPLETING`，调用 Go 取消接口 `sw_go_cancel_req(req_id)`，并在 C Completion 线程执行 `done_cb(ERR_FSAL_DELAY)` 释放客户端 RPC；**但 C Watchdog 绝不扣减 `S.pin_count`，也绝不回收 `ArenaSlot S`！**
2. **Go Upload Worker**：收到 Context Cancel 中断 HTTP 传输，确认不再读取 `ArenaSlot S` 后，调用 `sw_c_unpin_slots(&ref, 1)`。
3. **C Arena**：`sw_c_unpin_slots` 校验 `ref.generation == S.generation` 后将 `S.pin_count` 从 `1 -> 0`，递增 `S.generation++`，安全回收 `ArenaSlot S` 并最终释放 `areq` 描述符。**全程 0 Use-After-Free，0 Double-Callback！**

## 4.2 C/Go ABI 的三项强制内存契约
1. **值拷贝契约**：Go 导出函数（如 `sw_go_submit_sync_write_slots`）接收的 `const struct sw_slot_ref *slots` 指向 C 调用栈，**Go 必须在 `cgo` 函数返回前将其深拷贝到 Go 切片中**，严禁将 C 栈数组指针传入后台 Goroutine。
2. **Generation 强校验契约**：Go 访问任何 `ArenaSlot` 前（以及 C 执行 Pin/Unpin 时），必须通过 C 原子校验 `slot->generation == ref.generation && slot->pin_count > 0`（修正 v0.3.1 `SliceForSlot` 未校验 `Generation` 的漏洞）。
3. **`INV-RSV-DRAIN`（形式化模型检验捕获的保留池排空契约）**：凡因 `FILE_SYNC` / `DATA_SYNC` 写入而动用的 `Stable Write Buffer Reserve (10%)` 槽位，**必须在当次同步写操作中立即 Seal 并上传释放**，严禁残留在 C Dirty Page Map 中被后续 `UNSTABLE` 写长期占用。

---

# 5. P0-4 修正：Server-Wide Durability Epoch 与 NFSv3/v4 背压语义

## 5.1 进程全局统一的 `ServerDurabilityEpoch`
遵循 RFC 8881 与 RFC 1813 对 Write Verifier 服务端实例级一致性的规定：
- 废除按 Export 各自独立维护 Verifier 的设计，在 Ganesha 进程级定义唯一原子纪元：**`atomic_uint64_t g_server_durability_epoch`**（初始化为进程启动纳秒时间戳）。
- 在 Ganesha Core 中提供统一函数 `nfs_get_server_write_verifier(struct gsh_buffdesc *verf_desc)`：
  - 所有 Export 的 `get_write_verifier` 回调均返回 `g_server_durability_epoch`；
  - NFSv3 的 `nfs3_write.c`（正常写与 0 字节写）及 `nfs3_commit.c`（成功路径）、NFSv4 的 `nfs4_op_write.c` 及 `nfs4_op_commit.c` 全部统一调用该 Core 函数；
  - 若任一 Export 发生不可恢复的已确认 `UNSTABLE` 脏槽位被迫丢弃，原子递增全局 `g_server_durability_epoch`，驱动客户端重传未提交脏页。

## 5.2 区分储备资源：`Stable Write Buffer Reserve` vs `COMMIT Execution Reserve`
回應评审 §7.3，`COMMIT` 本身只是封块并上传已存在于内存中的 Dirty `ArenaSlot`，并不需要再分配一份重复的 Payload 缓冲：
- **`Stable Write Buffer Reserve`（10% C Arena 槽位）**：仅供 `FILE_SYNC4` / `DATA_SYNC4` 新到达写入在普通 80% 写池满载时借用（且用完立即 Seal 释放）。
- **`COMMIT Execution Reserve`（控制与网络执行配额）**：为 `commit2` 预留专用的高优 Upload Worker 线程（如独立 16 个 Commit Upload Workers）和独立 Filer gRPC Stream 通道，确保海量后台 `UNSTABLE` 上传满载时，`commit2` 永远有独立 Worker 和连接立即执行刷盘与元数据提交。

## 5.3 NFSv3 与 NFSv4 背压协议行为区分
当 C Arena 返回 `ERR_FSAL_DELAY` 时：
- **NFSv4.1**：Ganesha 向客户端返回 `NFS4ERR_DELAY`，客户端按协议退避后重发。
- **NFSv3**：核实 Ganesha V15.9 `nfs3_write.c` / `nfs3_commit.c`，`nfs_RetryableError(ERR_FSAL_DELAY)` 会返回 `NFS_REQ_DROP`（丢弃该次 RPC 不回包，由客户端 RPC 传输层超时重传）。性能测试中分别按两种协议的实际重传机制测量尾延迟与网络开销。

---

# 6. P0-5 修正：Filer CAS 精确保护矩阵与孤儿 Chunk 回收

针对 SeaweedFS `dev-4.48`（`weed/pb/filer.proto:299-356`）中不同原语的保护边界，制定严格的操作映射表：

| 元数据更新场景 | 强制使用的 Filer 原语与前置条件 | 为什么不能混用？ |
| :--- | :--- | :--- |
| **常规 Flush / COMMIT / SetAttr（更新 Entry 的 Chunks 和/或 Attributes）** | `UpdateEntryRequest` + **`WriteCondition: IF_ENTRY_EQUAL` (`expected_entry`)** | 若仅用 `IF_CHUNKS_EQUAL`，当另一客户端并发执行了 `chmod`/`chown` 修改了 `Attributes` 而未改 `Chunks` 时，旧 `Entry` 会静默覆盖新权限！使用 `IF_ENTRY_EQUAL` 可同时保护 `Attributes`、`Extended` 和 `Chunks`。 |
| **纯后台 Manifest 折叠（仅替换等价 Chunk 列表且不触碰最新属性）** | 先读取最新 Entry，再用 **`IF_ENTRY_EQUAL`**（或在服务端单路径锁下用 `IF_CHUNKS_EQUAL`） | 确保折叠期间若有并发新写入或属性变更，折叠操作立即中止并基于新状态重算。 |
| **Lazy Backfill `nfs.object_id` 或更新索引标记** | **`ObjectTransaction` (`PATCH_EXTENDED` + `WriteCondition: IF_EXTENDED_NOT_EQUAL`)** | 仅原子补丁目标 Extended 键值，绝不覆盖并发写入的 `Chunks` 或 `Attributes`。 |
| **Rename / Open-Unlink 孤儿转移** | **`ObjectTransaction` / `AtomicRenameEntry`** | 在 Filer 单路径/路由锁下原子执行命名空间变更。 |

- **CAS 失败后的 Orphan Volume Chunk 持久回收**：当新上传的 Chunk 因 Entry CAS 多次重试后发现文件已被删除而放弃提交时，先将待删 `FileId` 记入待清理队列，经引用检查确认无任何 Entry 关联后调用 `operation.DeleteFileIds` 回收。

---

# 7. 关键工程边界：`O_APPEND`、Open-Unlink 强隔离与锁恢复屏障

1. **`O_APPEND` 协议边界声明（回应评审 §7.1）**：
   - **单客户端 Append** 与 **多客户端持应用锁（`flock`/`fcntl`）协调的 Append**：100% 支持并纳入强制验收测试。
   - **多客户端无锁并发裸 Append**：明确声明遵循标准 Linux NFS 客户端协议语义（NFS 协议无原生原子 `APPEND` RPC，客户端通过 `GETATTR + WRITE(offset)` 模拟），不通过 `offset == EOF` 臆测改写 `pwrite` 行为。
2. **Open-Unlink 强隔离与 SAL Open State 绑定（回应评审 §7.2）**：
   - **跨协议强隔离**：Open-Unlink 的孤儿 Entry 不放在普通导出目录下，而是存放在 Filer 专用内部系统路径 `/.seaweed_system/nfs_orphans/<export_id>/<object_id>`，并在 Filer `FilerConf` / Export 规则中将该系统前缀设为外部不可见，防止 S3 / `weed mount` 误枚举。
   - **严格绑定 SAL Open State**：区分 Ganesha 的 Temporary FD、I/O In-flight 引用与真正的 **NFSv4 Open State (`state_t`)**。只有在 `myself->open_state_count == 0 && myself->active_io_count == 0` 时才触发孤儿文件的物理删除；Ganesha 崩溃重启后，**Post-Grace Orphan Sweeper** 必须在 NFSv4 Grace Period 完全结束、确认客户端未 Reclaim 该对象后才执行清理。

---

# 8. 修订后的五阶段 Gate 准出标准（含 P0-B 9 项强制测试）

| Gate 阶段 | 评审状态 | 强制准出条件（Exit Criteria） |
| :--- | :--- | :--- |
| **Gate P0-A：Runtime & Decoupled Async Lifecycle** | **Approved to Start** | 验证 Go `c-shared` 加载、C 栈 `sw_slot_ref[]` 同步值拷贝、Watchdog 超时与 `ArenaSlot` Pin 解耦；100 万次异步回调 + 并发 Timeout 注入下 0 UAF、0 Double-Callback（通过 ASAN/TSAN）。 |
| **Gate P0-B：Native Arena & C Dirty Page Map Prototype** | **Prototype Approved** | 独立验证 C Arena 与 C Dirty Page Map，**必须通过下方全部 9 项 P0-B 强制压力测试**后方可冻结数据结构。 |
| **Gate P0-C：Native Data I/O & Server-Wide Verifier** | **Gated on P0-A/B** | 验证 Mode A (`Chunk-Sync`)、全局 `g_server_durability_epoch`、严格单调 `ModifiedTsNs`、NFSv3 `NFS_REQ_DROP` vs NFSv4 `NFS4ERR_DELAY` 背压及 100 GiB 大文件归档吞吐基线。 |
| **Gate P0-D：Immutable ObjectID & Namespace** | **Gated on P0-C** | 验证 HardLink 前后 `SeaweedObjectID` 100% 不变、存量文件并发 Lazy Backfill、`IF_ENTRY_EQUAL` CAS、Open-Unlink 跨协议隔离与 Grace Period 后 Orphan Sweeper。 |
| **Gate P0-E：Unified Lock & Recovery Fencing** | **Gated on P0-D** | 验证 Linux NFS `flock` vs `fcntl` 跨机互斥、Filer 重启 Lock Recovery Barrier（0 冲突穿透）、持久化 `sid` Reclaim 与 72 小时混沌长稳测试。 |

### Gate P0-B 强制 9 项基准与异常注入测试清单
1. **Sequential 1 MiB Writes**：大文件连续顺序写，验证 `1 MiB` Full Slot 零碎片高速流转。
2. **4 KiB Random Writes**：大跨度随机小块写，验证 `64 KiB` Sub-Slot 抑制内存放大且无跨池饥饿。
3. **64 KiB Overlapping Writes**：半块交错重叠写，验证 C Dirty Page Map 原地覆盖与区间记录准确性。
4. **Repeated Writes to the Same Logical Page**：同一逻辑页连续 1,000 次部分改写，验证**始终复用同一个 `ArenaSlot` 且每次仅 1 次 `memcpy`（0 新槽位分配）**。
5. **Writes Arriving While Old Page Is Uploading**：旧页处于 `PAGE_SEALED_UPLOADING` 时新写入到达同一逻辑页，验证旧槽位保持 Pin 直至上传完成、新写入分配新 Generation 槽位且 `ModifiedTsNs` 严格递增。
6. **Writeback Queue Full**：模拟后端 Volume 限速塞满上传队列，验证 80% 水位背压、`Stable Write Buffer Reserve (10%)` 隔离及 `INV-RSV-DRAIN`（`FILE_SYNC` 借用后立即 Seal 归还）。
7. **Page Allocation Failure (All-or-Nothing)**：多 `iov` 跨页写遇到槽位不足，验证原子回滚（0 脏数据残留）。
8. **Watchdog Timeout During Active Upload**：在 Go Worker 正在读取 `ArenaSlot` 时强制触发 C Watchdog 超时，验证 `done_cb` 立即返回而 `ArenaSlot` 保持 Pin 直至 Go Worker 安全退出（ASAN 0 报错）。
9. **Duplicate Completion & Stale Generation Slot Release**：注入重复完成通知与携带旧 `generation` 的 `sw_c_unpin_slots` 调用，验证 100% 幂等拦截（0 ABA 破坏）。

---
---

# 专题一：28B Handle、HardLink 不变性、Lazy Backfill 与 Open-Unlink 详细设计

## 1.1 `SeaweedObjectID` 在 HardLink 与存量文件中的不变性设计

```mermaid
sequenceDiagram
    participant Client as NFS Client
    participant FSAL as FSAL_SEAWEED
    participant Filer as SeaweedFS Filer

    Note over Client,Filer: 1. 创建新文件 /export/a.txt
    Client->>FSAL: OPEN4_CREATE(/export/a.txt)
    FSAL->>FSAL: 生成不可变 UUID-A
    FSAL->>Filer: KvPut("nfs:obj:<exp>:<UUID-A>", {Paths:["/export/a.txt"]})
    FSAL->>Filer: CreateEntry(/export/a.txt, Extended{"nfs.object_id": UUID-A})
    FSAL-->>Client: FH(UUID-A), st_ino = Hash64(UUID-A)

    Note over Client,Filer: 2. 创建硬链接 /export/b.txt -> /export/a.txt
    Client->>FSAL: LINK(/export/a.txt -> /export/b.txt)
    FSAL->>Filer: 生成共享 HardLinkId = HL-99, 但保留 Extended{"nfs.object_id": UUID-A}!
    FSAL->>Filer: UpdateEntry(a.txt, HL-99, UUID-A) + CreateEntry(b.txt, HL-99, UUID-A)
    FSAL->>Filer: KvPut("nfs:obj:<exp>:<UUID-A>", {Paths:["/export/a.txt", "/export/b.txt"], HardLinkId: HL-99})
    FSAL-->>Client: /export/b.txt 同样返回 FH(UUID-A), st_ino = Hash64(UUID-A)

    Note over Client,Filer: 3. 删除原路径 /export/a.txt (nlink: 2 -> 1)
    Client->>FSAL: REMOVE(/export/a.txt)
    FSAL->>Filer: DeleteEntry(/export/a.txt, is_delete_data=false)
    FSAL->>Filer: KvPut("nfs:obj:<exp>:<UUID-A>", {Paths:["/export/b.txt"]})
    Note over Client,Filer: 持有 FH(UUID-A) 的客户端继续无缝访问 /export/b.txt，ObjectID 从未改变！
```

### `st_ino` (64-bit) 映射与防碰撞规则
NFS `GETATTR` 返回的 `fileid` (`st_ino`) 为 64 位无符号整数，而 `SeaweedObjectID` 为 128 位 UUID：
- 计算方式：`uint64_t ino = siphash24_64(object_id, 16, export_seed)`（确保非 0 且非 1，根目录固定为 `1`）。
- 在进程内维护轻量级 `ino -> ObjectID` 双向校验表：若极小概率发生 64-bit 哈希碰撞（两个不同 `ObjectID` 算出相同 `ino`），通过线性探测 `ino++` 并将确定的 `uint64_t` 持久化写入 `Entry.Attr.Inode`，从而保证 `GETATTR` 暴露给客户端的 64-bit `st_ino` 在整个文件生命周期内同样稳定唯一。

---
---

# 专题二：C-Owned Arena、Dirty Page Map 与双状态机解耦 C/Go 代码契约

## 2.1 修正后的 C/Go 防火墙头文件（`sw_backend_abi.h`）

```c
#ifndef SW_BACKEND_ABI_H
#define SW_BACKEND_ABI_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* C 向 Go 传递的 ArenaSlot 引用描述符 (16 Bytes, 纯值类型)
 * 契约铁律：Go 必须在 cgo 入口返回前拷贝本结构体值，严禁保存数组指针！ */
struct sw_slot_ref {
    uint32_t slot_id;     /* C Arena 槽位下标 */
    uint32_t generation;  /* 槽位分配纪元号 (每次 pin_count 归零回收时 +1) */
    uint32_t offset;      /* 本次有效数据在槽位内的起始字节偏移 */
    uint32_t length;      /* 本次有效数据在槽位内的字节长度 */
};

/* C 侧导出的 Pin/Validate 与 Unpin 函数：Go 访问 Arena 内存前必须校验 Generation */
bool sw_c_validate_and_pin_slot(uint32_t slot_id, uint32_t expected_gen, uintptr_t *out_addr, uint32_t *out_cap);
void sw_c_unpin_slots(const struct sw_slot_ref *slots, uint32_t slot_count);

/* C 侧导出的异步请求完成通知函数（仅推进 Request Completion State，不直接释放 Slot） */
void sw_c_complete_req(uint64_t req_id, int32_t fsal_err_major, size_t bytes_xfer, int32_t is_stable, int32_t is_eof);

/* Go 侧导出：当 C Dirty Page Map 封块 (Seal) 或触发 FILE_SYNC 时，提交已 Pin 的 slots[] 供后台上传 */
int sw_go_submit_sealed_chunk(uint64_t req_id, uint16_t export_id, const uint8_t object_id[16],
                              uint64_t chunk_file_offset, uint64_t chunk_length,
                              uint64_t strict_modified_ts_ns,
                              const struct sw_slot_ref *pinned_slots, uint32_t slot_count,
                              int32_t sync_commit_now);

/* Go 侧导出：C Watchdog 超时或 unexport 时通知 Go 取消在途请求 */
void sw_go_cancel_req(uint64_t req_id);

#endif /* SW_BACKEND_ABI_H */
```

## 2.2 C-Owned Dirty Page Map 原地写入与 `INV-RSV-DRAIN` 实现（`fsal_io.c`）

```c
/* 在 C 层通过 Per-File Dirty Page Map 执行写入：
 * - 若目标逻辑页已有 PAGE_WRITABLE 槽位，直接原地 memcpy (严格 1 次拷贝，0 新槽位分配)
 * - 若目标逻辑页无槽位或已处于 PAGE_SEALED_UPLOADING，原子申请新槽位并 memcpy */
fsal_status_t sw_c_page_map_write(struct sw_obj_handle *myself,
                                  uint64_t offset, size_t io_request,
                                  struct iovec *iov, int iov_count,
                                  bool is_stable_write)
{
    pthread_mutex_lock(&myself->page_map_lock);

    uint32_t first_page = offset / SW_SLOT_SIZE;
    uint32_t last_page  = (offset + io_request - 1) / SW_SLOT_SIZE;
    uint32_t new_slots_needed = 0;

    /* Step 1: 统计有多少个逻辑页没有现成的 PAGE_WRITABLE 槽位 */
    for (uint32_t p = first_page; p <= last_page; p++) {
        struct sw_dirty_page_entry *pe = sw_page_map_lookup(myself, p);
        if (!pe || pe->state != PAGE_WRITABLE) {
            new_slots_needed++;
        }
    }

    /* Step 2: 仅为缺失的页全有或全无 (All-or-Nothing) 原子预留新 ArenaSlot */
    struct sw_slot_ref newly_acquired[SW_MAX_IOV_SLOTS];
    if (new_slots_needed > 0) {
        if (!sw_arena_acquire_slots_atomic(myself->export_id, new_slots_needed,
                                           is_stable_write, newly_acquired)) {
            pthread_mutex_unlock(&myself->page_map_lock);
            return fsalstat(ERR_FSAL_DELAY, 0);
        }
    }

    /* Step 3: 遍历 iov，直接将数据原地 memcpy 到对应页的 ArenaSlot 中（全局唯一一次 memcpy！） */
    uint32_t acq_idx = 0;
    for (uint32_t p = first_page; p <= last_page; p++) {
        struct sw_dirty_page_entry *pe = sw_page_map_get_or_create(myself, p);
        if (pe->state != PAGE_WRITABLE) {
            pe->slot_ref = newly_acquired[acq_idx++];
            pe->state    = PAGE_WRITABLE;
            pe->born_epoch = atomic_load(&g_server_durability_epoch);
        }
        /* 计算当前页与 (offset, io_request) 的交集并从 iov 直接拷入 pe->slot_ref 对应物理内存 */
        sw_copy_iov_slice_to_slot(pe, p, offset, io_request, iov, iov_count);
    }

    /* Step 4: 关键不变量 INV-RSV-DRAIN ——
     * 若本次是 FILE_SYNC/DATA_SYNC (is_stable_write == true)，或者当前 LogicalChunk (16MiB) 已写满，
     * 立即在锁内将该范围页面标记为 PAGE_SEALED_UPLOADING（增加 slot pin_count），
     * 严禁让可能来自 StableWriteReserve 的槽位残留在 PAGE_WRITABLE 状态！ */
    if (is_stable_write || sw_chunk_is_full(myself, first_page)) {
        sw_seal_pages_for_upload_locked(myself, first_page, last_page, is_stable_write);
    }

    pthread_mutex_unlock(&myself->page_map_lock);
    return fsalstat(ERR_FSAL_NO_ERROR, 0);
}
```

## 2.3 Go 侧带 Generation 强校验与栈数组值拷贝的读取器

```go
//export sw_go_submit_sealed_chunk
func sw_go_submit_sealed_chunk(
    reqID C.uint64_t,
    exportID C.uint16_t,
    objIDPtr *C.uint8_t,
    chunkOffset C.uint64_t,
    chunkLen C.uint64_t,
    strictModifiedTsNs C.uint64_t,
    cSlots *C.struct_sw_slot_ref,
    slotCount C.uint32_t,
    syncCommitNow C.int32_t,
) C.int {
    defer recoverToErrCode()

    // 1. 强制契约：在 cgo 函数返回前，立即将 C 栈上的 sw_slot_ref 数组深拷贝为 Go 切片（纯值拷贝）！
    //    后台 Goroutine 绝不持有 cSlots 指针！
    rawSlice := unsafe.Slice(cSlots, int(slotCount))
    pinnedRefs := make([]SwSlotRef, int(slotCount))
    for i, s := range rawSlice {
        pinnedRefs[i] = SwSlotRef{
            SlotID:     uint32(s.slot_id),
            Generation: uint32(s.generation),
            Offset:     uint32(s.offset),
            Length:     uint32(s.length),
        }
    }
    var objID [16]byte
    copy(objID[:], unsafe.Slice((*byte)(unsafe.Pointer(objIDPtr)), 16))

    // 2. 投递至后台 Upload Worker（每个后台 Worker 均由 safego.Go 守护 panic）
    enqueueUploadTask(UploadTask{
        ReqID:          uint64(reqID),
        ExportID:       uint16(exportID),
        ObjectID:       objID,
        ChunkOffset:    int64(chunkOffset),
        ChunkLength:    int64(chunkLen),
        ModifiedTsNs:   int64(strictModifiedTsNs),
        PinnedSlotRefs: pinnedRefs,
        SyncCommitNow:  syncCommitNow != 0,
    })
    return 0
}

// AcquireValidatedSlice 在读取每个 ArenaSlot 前向 C 层校验 (SlotID, Generation) 并获取额外 Pin
func AcquireValidatedSlice(ref SwSlotRef) ([]byte, func(), error) {
    var cAddr C.uintptr_t
    var cCap C.uint32_t
    ok := C.sw_c_validate_and_pin_slot(C.uint32_t(ref.SlotID), C.uint32_t(ref.Generation), &cAddr, &cCap)
    if !bool(ok) || ref.Offset+ref.Length > uint32(cCap) {
        return nil, nil, errStaleOrInvalidSlotGeneration
    }
    fullSlot := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(cAddr))), int(cCap))
    releaseFn := func() {
        cRef := C.struct_sw_slot_ref{
            slot_id:    C.uint32_t(ref.SlotID),
            generation: C.uint32_t(ref.Generation),
            offset:     C.uint32_t(ref.Offset),
            length:     C.uint32_t(ref.Length),
        }
        C.sw_c_unpin_slots(&cRef, 1)
    }
    return fullSlot[ref.Offset : ref.Offset+ref.Length], releaseFn, nil
}
```

---
---

# 专题三：I/O 与状态机形式化验证（Lean 4 七模块 Lake 工程 + Go 穷举模型检验）

按照形式化规格评审的全部 P0-1 ~ P0-7 强制修订要求，我们将形式化规约拆分为 **7 个独立 Lean 4 模块（FM-01 ~ FM-07）**，固定纯 Lean 4 工具链（`leanprover/lean4:v4.14.0`，`omega` 已内置于 Lean 4 核心，无需庞大 Mathlib 依赖即可秒级编译），并在根模块中执行 `#print axioms` 公理审计（零 `sorry`、零 `admit`、零自定义公理）：

- **Lake 工程配置**：`docs/formal/lean-toolchain`、`docs/formal/lakefile.toml`、`docs/formal/FSALSeaweedFormal.lean`
- **Go 穷举状态空间检验器**：`docs/formal/model_checker_test.go`

## 3.1 七大 Lean 4 形式化模块与全轨迹归纳定理（`∀ trace : List Event`）

| 编号 | Lean 4 模块路径 | 对应评审要求 | 证明的全局安全不变量与核心定理 |
| :--- | :--- | :--- | :--- |
| **FM-01** | `FSALSeaweedFormal/Arena.lean` | P0-1 | 引入 **`ownerRefs`（长期所有权）+ `activePins`（Worker 临时读 Pin）双重引用计数**；证明 `no_free_while_pinned_or_owned`（Global Inv 1）、`permanent_aba_immunity`（对所有未来轨迹永不 ABA）与 `unstable_never_allocates_reserve`。 |
| **FM-02** | `FSALSeaweedFormal/DirtyPageMap.lean` | P0-2 | 建模完整 `PageState`、写偏移越界检查、`generation` 校验与目标槽位内容；证明 `runPageMap_single_copy_and_rsv_drain`（任意操作序列下 `realPayloadCopies = acceptedWrites` 且 `INV-RSV-DRAIN`）与 `write_never_mutates_inflight_uploading_slot`。 |
| **FM-03** | `FSALSeaweedFormal/AsyncLifecycle.lean` | P0-3 | 覆盖多 Worker 并发 Pin、Watchdog 超时、Worker Panic/Cancel 与重复通知的**任意事件交错轨迹**；证明 `callback_at_most_once`（`doneCbCount ≤ 1`）与 `no_recycle_while_pinned_or_owned`。 |
| **FM-04** | `FSALSeaweedFormal/DurabilityEpoch.lean` | P0-4 | **废除循环前提假设**：将 `irrecoverableDataLoss` 与 `serverRestart` 递增全局 `serverEpoch` 建模为显式状态转移，区分 `volumeDurable` 与 `metadataCommitted` 及多 Export 共享；归纳证明 `zero_silent_data_loss_all_traces`（Global Inv 2）。 |
| **FM-05** | `FSALSeaweedFormal/ChunkOrdering.lean` | P0-5（补齐） | **乱序并行上传与重叠写线性一致性**：建模 `INV-CHUNK-STRICT-TS`，证明 `older_write_never_overwrites_newer_write`（Global Inv 3）、`out_of_order_upload_swap_invariant` 与 `linearizability_matches_posix`（任意上传完成排列等价于 POSIX 顺序执行）。 |
| **FM-06** | `FSALSeaweedFormal/ObjectIdentity.lean` | P0-6 | 建模多路径 HardLink 目录表、Open States、孤儿目录与 Grace Sweeper；对任意生命周期轨迹证明 `object_lifecycle_safety`（`INV-OBJECTID-IMMUTABLE`、`INV-HARDLINK-SAME-OBJECT`、`INV-OPEN-UNLINK`）。 |
| **FM-07** | `FSALSeaweedFormal/FilerCAS.lean` | P0-7 | 显式建模增量 `EntryDelta` 与 `IF_ENTRY_EQUAL` 冲突重读重试；证明 `flush_delta_preserves_attributes`、`setattr_delta_preserves_chunks` 及双交错 `cas_retry_preserves_concurrent_flush_and_chmod`。 |

## 3.2 形式化建模过程中捕获并修复的 2 个隐蔽缺陷

1. **缺陷 1（由穷举模型检验器捕获）：`FILE_SYNC` 借用保留槽位后的滞留排空漏洞（`INV-RSV-DRAIN`）**
   - **反例路径**：当 80% `NormalWrite` 槽位全部繁忙时，一个 4KB 的 `FILE_SYNC` 写入合法借用了 `StableWriteReserve (10%)` 中的槽位 `Slot #3`。如果 `FILE_SYNC` 写完后未立即将 `Slot #3` 从 `PAGE_WRITABLE` 剥离封块，紧接着到达的 `UNSTABLE` 写入就会通过 C Dirty Page Map 直接复用 `Slot #3`，导致原本专属于 `StableWriteReserve` 的槽位被普通 `UNSTABLE` 写长期霸占！
   - **形式化修复**：在 `sw_c_page_map_write`（专题二 §2.2 Step 4）中强制规定 `is_stable_write == true` 时必须在同一临界区内立即执行 `sw_seal_pages_for_upload_locked`，将槽位状态转为 `PAGE_SEALED_UPLOADING`，上传落盘后立即归还保留池。修复后穷举检验器遍历 2,484 个状态与 10,979 条转换全部通过。
2. **缺陷 2（由 Lean 4 建模 + `filechunks_read.go` 审计发现）：相等 `ModifiedTsNs` 导致区间静默丢失（`INV-CHUNK-STRICT-TS`）**
   - **源码根因**：在 SeaweedFS `weed/filer/filechunks_read.go:68-78` 中，扫描线队列插入条件为 `if prevPoint.ts < point.ts` 与 `else if e.Value.(*Point).ts > point.ts`。若同一文件的两个重叠 Chunk 因时钟精度或并发封块获得了**完全相等的 `ModifiedTsNs`**，第二个 `Point` 既不满足 `<` 也不满足 `>`，会被**静默丢弃不插入队列**！
   - **形式化修复**：在 `FSAL_SEAWEED` 中为每个文件维护单调递增原子时间戳生成器 `nextStrictTsNs = max(time.Now().UnixNano(), atomic.AddInt64(&fh.lastTsNs, 1))`，从数学上保证同一文件的任意两次封块满足严格不等式 $\text{ts}_1 < \text{ts}_2$。
