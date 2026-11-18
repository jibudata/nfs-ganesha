# 数据一致性与持久性验证（Ganesha → weed FUSE → SeaweedFS 4.54）

> 更新：2026-11-18
> 运行版本：SeaweedFS **4.54**、Ganesha **15.9**、fio 3.36
> 说明：本地 `/home/ys1000/src/github.com/jibudata/seaweedfs` 是 **4.48** 分支；本文的
> SeaweedFS 代码引用核对的是 4.54 release 源码（`/tmp/seaweedfs-4.54`）。两者写路径架构一致，
> 行号可能不同。

## 1. 结论

`fio end_fsync=1` 正常返回，**不能无条件解释为“所有 cache 都已落盘”**。在当前默认配置下：

- **能保证**：数据已离开 weed mount 的写缓冲，chunk 已上传到 volume server，文件的
  chunk 引用已提交到 filer（CreateEntry 成功返回）。
- **不能保证**：volume server 的 `.dat` 已经 fsync 到 NVMe；filer 的 LevelDB 已经 Sync
  到磁盘。默认配置没有 filer storage rule 的 `fsync`，因此这两步都走普通缓冲写。
- **进程崩溃**（mount / Ganesha / volume server / filer 进程被杀但 VM 还在）：实测可恢复，
  因为操作系统页缓存仍在。
- **断电 / VM 强制崩溃**：可能丢失最近写入和最近元数据。需要 `fsync=true` 存储规则、
  或关机前 `sync`。

## 2. 调用链（代码级）

```text
fio fsync()
  → Linux NFS client: fsync → COMMIT / stable WRITE
  → Ganesha: nfs4_op_commit / nfs4_op_write
  → FSAL VFS: fsync(fd)                     [FD 指向 FUSE 文件]
  → weed mount: Fsync → doFlush(同步)
       → dirtyPages.FlushData()             上传所有脏 chunk
       → flushMetadataToFiler()             向 filer CreateEntry
  → volume server: POST /<fileId>[?fsync=true]
  → filer: LevelDB Put / Batch(WriteOptions)
```

### 2.1 Ganesha 侧

| 位置 | 行为 |
|---|---|
| `src/Protocols/NFS/nfs4_op_commit.c:96` | `fsal_commit(...)` |
| `src/include/fsal.h:403-411` | `obj->obj_ops->commit2(obj, offset, len)` |
| `src/FSAL/FSAL_VFS/file.c:1652-1689` | `vfs_commit2()` → **`fsync(my_fd->fd)`** |
| `src/Protocols/NFS/nfs4_op_write.c:571` | `write_arg->fsal_stable = stable != UNSTABLE4 || force_sync` |
| `src/FSAL/FSAL_VFS/file.c:1399-1404` | stable WRITE 也调用 `fsync(fd)` |

结论：Ganesha 正确地把 NFSv4 COMMIT/stable WRITE 传递成对 FUSE 文件的 `fsync(2)`。

### 2.2 weed mount 侧（4.54）

| 位置 | 行为 |
|---|---|
| `weed/command/mount.go:160` | `-writebackCache` 默认 **false** |
| `weed/mount/weedfs_file_sync.go:150-161` | `Fsync()` → `doFlush(..., allowAsync=false)`，注释明确 “always flush synchronously” |
| `weed/mount/weedfs_file_sync.go:199` | `fh.dirtyPages.FlushData()` —— 上传所有脏数据 |
| `weed/mount/weedfs_file_sync.go:227` | `flushMetadataToFiler(...)` —— 提交 chunk 引用/属性 |
| `weed/mount/weedfs_file_sync.go:351` | `filer_pb.CreateEntryRequest` |

`Fsync` 只有在数据上传**和**元数据提交都成功后才返回。`-writebackCache` 只影响
close() 触发的异步 flush；即使开启，显式 fsync 仍然同步。

### 2.3 chunk 上传是否请求 volume fsync

| 位置 | 行为 |
|---|---|
| `weed/operation/assign_file_id.go:41-43` | assign 结果携带 storage rule 的 `Fsync` |
| `weed/operation/upload_content.go:302` | 上传 URL 在 `Fsync` 时追加 `?fsync=true` |
| `weed/server/filer_server_handlers_write.go:75-78` | filer 自身上传路径同样按 `so.Fsync` 追加 |
| `weed/topology/store_replicate.go:59-62` | volume server 解析 `fsync=true` |
| `weed/storage/volume_write.go:175-...` | `syncWrite(..., fsync)` / async batch worker |
| `weed/command/volume.go:253` | `-fsyncMinBatchBytes` 默认 1 MiB（批量 fsync 合并） |

没有 storage rule 时，上传请求**不带** `?fsync=true`，volume server 只把 needle 写入
`.dat`（经页缓存），不保证在返回前落盘。

### 2.4 filer 元数据是否 Sync

| 位置 | 行为 |
|---|---|
| `weed/filer/filer.go:487-494` | storage rule `Fsync` → `WithSyncWrite(ctx)` |
| `weed/filer/leveldb/leveldb_store.go:76-82` | `SyncWrite(ctx)` → `WriteOptions{Sync: true}` |
| `weed/filer/leveldb/leveldb_store.go:97/174/205` | Put/Delete/WriteBatch 使用上述选项 |

没有 rule 时使用 LevelDB 默认写选项（**不强制 Sync**）。

## 3. 实测结果

### 3.1 跨 mount 一致性（当前性能配置）

| 方向 | 大小 | 结果 |
|---|---:|---|
| host 写 → pod 读 | 2 GiB | sha256 `7aa266b6…` 两边一致 |
| pod 写 → host 读 | 2 GiB | sha256 `1ecb39a8…` 两边一致 |

注意：另一 mount 的元数据缓存 `-cacheMetaTtlSec=60`，新文件**最多延迟 60 s** 可见；
之后读取内容一致。这是最终一致，不是数据损坏。

### 3.2 进程崩溃（同一 VM，页缓存仍在）

| 故障 | 操作 | 结果 |
|---|---|---|
| FUSE mount 崩溃 | pod 写 12 GiB（351 MiB/s，end_fsync rc=0，sha256 `20ba9a44…`）→ `kill -9` weed mount → 容器重启（RESTARTS=1）→ NFS 重新挂载 | 文件大小 12 GiB，**sha256 一致** |
| volume server 崩溃 | `kubectl delete pod seaweedfs-volume-0 --grace-period=0 --force` → 等 StatefulSet 重建 → 同时重启 pod 臂 FUSE（清 tmpfs cache）→ NFS 重新挂载 | **sha256 一致** |

这两项证明：fsync 后数据已经到 volume server / filer，进程级崩溃可恢复。
它们**不能**证明断电安全——测试期间 VM 一直在运行，页缓存没有丢。

### 3.3 fsync=true 存储规则（durable-on-ack 路径）

```bash
# 应用
printf 'fs.configure -locationPrefix=/data/ -fsync -apply\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
  /usr/local/bin/weed shell -master=172.18.0.2:9333 -filer=127.0.0.1:8888

# 撤销
printf 'fs.configure -locationPrefix=/data/ -delete -apply\nexit\n' | ...
```

同样 12 GiB pod 写（numjobs=1）：

| 配置 | 吞吐 | 语义 |
|---|---:|---|
| 无 rule（默认） | 351 MiB/s | 上传 + 元数据提交，**不保证 NVMe 落盘** |
| `fsync=true` | **253 MiB/s**（约 -28%） | volume server fsync `.dat` + filer LDB `Sync:true` |
| `fsync=true` + 64 MiB/5 ms batch | 264 MiB/s（12G/1job）、259 MiB/s（24G/2jobs） | 同上；批量只小幅改善 |

volume 的 fsync 批量参数（`weed server` 下带前缀；`weed volume` 下无前缀）：

```text
-volume.fsyncMinBatchBytes   默认 1 MiB     （一个 8 MiB chunk 就超过）
-volume.fsyncMinBatchRequests 默认 128
-volume.fsyncBatchWait       默认 500 µs
```

默认值适合小请求；本测试的 8 MiB chunk 会退化为“每 chunk 一次 fsync”。但即使把 batch 放大到
64 MiB，也只从 253 提升到 264（1 job）/259（2 jobs），说明 ~25–30% 的代价主要来自 fsync
语义本身（ack 等 fsync + filer LDB Sync），不是 fsync 次数。

### 3.4 OS 每秒回写档（MySQL auto 式）

不启用 fsync rule，把 OS 回写周期收紧到 1 s：

```bash
sudo sysctl -w vm.dirty_expire_centisecs=100
sudo sysctl -w vm.dirty_writeback_centisecs=100
```

12 GiB pod 写实测：**396 MiB/s**（与默认 30 s 回写的 351 相比无下降）。
语义：ack 不等待 fsync（类似 MySQL `innodb_flush_log_at_trx_commit=2`），断电最多丢最近
~1–2 s 的页缓存/元数据；设备自身易失写缓存仍未覆盖。

| 档位 | 配置 | 吞吐 | 断电丢失窗口 |
|---|---|---:|---|
| performance | 无 rule，默认 30 s 回写 | 351 / 343–439 | ~30 s |
| **auto（推荐）** | 无 rule，1 s 回写 | **396** | **~1–2 s** |
| group-commit | fsync rule + 批量 | 264 / 259 | 0（已确认写） |
| strict | fsync rule + 默认批量 | 253 | 0（已确认写） |

### 3.5 尚未执行：断电 / VM 强制崩溃

> 注意：对 pod / 进程 `kill -9`（volume server、weed mount、filer 等）只模拟**进程崩溃**，
> VM 的内核页缓存仍然存在；3.2 已验证这类故障可恢复。要模拟掉电，必须让 VM 的内核页缓存
> 丢失（SIGKILL qemu/colima VM 或物理断电），或在目标节点上执行下述步骤。

需要在**可丢弃**的节点上执行，步骤：

1. 记录 volume `.dat` 总量与目标文件预期 sha256；
2. 写 N GiB + `end_fsync=1`；
3. 在 fsync 返回后尽快**强制杀掉 VM**（SIGKILL qemu/colima VM，或物理断电），不要执行
   `sync` 或正常关机；
4. 重启 VM / K8s，等待 SeaweedFS Pod Ready；
5. 重新挂载 NFS，检查文件是否存在、大小、sha256；检查 volume `.idx` 恢复与 filer 元数据；
6. 分别在「无 fsync rule」和「fsync=true rule」两组下重复，比较丢失窗口。

预期：无 rule 组可能丢最近写入（页缓存）和最近元数据（LDB 未 Sync）；`fsync=true` 组应
保持完整（代价是 ~28% 吞吐）。

## 4. 建议

- **默认用 auto 档**（无 rule + 1 s OS 回写）：吞吐与 performance 档相同（396 vs 351，
  在噪声内），但断电丢失窗口从 ~30 s 缩到 ~1–2 s。
- **性能基准**：保持当前配置（无 fsync rule），报告中明确“fsync = 上传 + 元数据提交，
  不等于断电持久化”。
- **严格持久化**：对关键路径加 `fsync=true`（可选 group-commit 批量），接受 ~25–30%
  吞吐下降；3 节点/2 副本时在每个 volume server 上设置并实测。
- **需要 durable-on-ack**：对测试前缀加 `fsync=true`，接受吞吐下降；或选用更快的
  NVMe/降低 dirty 上限，但都不能完全替代 fsync。
- **不要开启 `-writebackCache`**：源码帮助文本明确写着 “at risk of data loss on crash”。
- **`-metadataFlushSeconds=120`** 只保护长时间打开的文件不被 `volume.fsck` 当成孤儿，
  不是持久化参数。
- **tmpfs cache**：只影响读缓存和写 spool；fsync 成功时对应文件的待上传数据已处理完，
  cache 在断电后丢失本身不会导致已 fsync 数据丢失（但默认配置下数据仍在 volume 页缓存）。
- **关机/迁移前**：对节点执行 `sync`，或确认后端已停止写入。
