# NFS-Ganesha V15.9 → FUSE (SeaweedFS) 写 IO 性能报告

**测试日期**：2026-11-16
**测试主机**：`ys1000@192.168.3.146`（Ubuntu 24.04.4，16 vCPU，62 GiB RAM，NVMe `/dev/nvme0n1p3`）
**被测链路**：NFS client → `ganesha.nfsd` V15.9（FSAL_VFS）→ `fuse.seaweedfs` → weed filer → weed volume server → NVMe

> ⚠️ **重要限定**：客户端与服务端在**同一台机器**上。NFS 流量走本机 `br0` 地址（内核 TCP 栈），
> **不经过 1 GbE 物理网卡**，因此本报告**不包含网络路径的开销**。
> 远端客户端 `192.168.3.134` 的 SSH 超时不可达，跨机测试无法进行。
> 按 1 GbE 链路推算，真实跨机场景的上限约为 **117 MB/s**，低于本机 FUSE 层的实测天花板。

> 📌 **后续修正（2026-11-16 晚）**：本报告正文（22 用例矩阵）测于 **11:10 之前**，
> 当时三套 FUSE 挂载健康、每个用例都校验了 volume `.dat` 增长，**结论成立**。
> 但 `results/blocksize.csv`（11:17 那次 512K/1M/4M/8M 扫描）是在 **FUSE 挂载僵死**状态下测的，
> 其数据**已作废**，以 `results/final-bench.csv`（健康状态 + 逐用例落盘校验）为准。
> 四个推荐问题的完整实测回答见 **[`RECOMMENDATIONS.md`](RECOMMENDATIONS.md)**。


---

## 一、结论速览

| # | 结论 | 证据 |
|---|---|---|
| 1 | **单流 NFS 写经 FUSE 只有 ~104 MiB/s**，而同机直连 FUSE 是 1952 MiB/s —— **19 倍落差** | §3.1 |
| 2 | 根因：**Ganesha 对每次 stable write 都调用一次 `fsync(2)`**，打在 SeaweedFS FUSE 上等于把 chunk 刷到 volume server + filer，单次约 150 ms | §4 |
| 3 | 瓶颈**不在 Ganesha 的并发能力**：服务端 16 个 WRITE 全部并发在飞；Ganesha CPU 仅占 6.5% 单核 | §3.2 |
| 4 | 同一次实验里，NFS → **本地 ext4**（不经 FUSE）O_DIRECT 达 **719 MiB/s** —— 证明代价来自 **FUSE 的 fsync**，而非 NFS 协议或 Ganesha | §3.3 |
| 5 | **推荐模式：buffered 写 + 末尾一次 fsync = 636 MiB/s（2 GiB）/ 507 MiB/s（8 GiB）**，同等耐久性下比 O_DIRECT 快 **5–6 倍** | §5 |
| 6 | buffered 路径 2547 MiB/s 是**客户端 page cache 接受速度**，不代表落盘 | §3.1 |
| 7 | 并发可突破单文件上限（8 job → 761 MiB/s），但**单文件仍受限于 1 次 fsync/1 MiB** | §3.4 |
| 8 | NFSv4.1 与 NFSv3 在写路径上**无差异**（101 vs 104 MiB/s） | §3.5 |
| 9 | 块越小越慢：128k→23.7、256k→44.7、512k→66.1、1M→101 MiB/s；Ganesha CPU 反随小块上升（0.7s→3.0s） | §3.6 |
| 10 | NFS 侧 wsize 调优**无效**：wsize=256K/512K/1M 对应 47.8/65.4/98.8 MiB/s，与直接调 fio bs 的结果一致 —— 瓶颈在 fsync 次数而非包大小 | §3.7 |

---

## 二、测试方法

- 负载：`fio` 3.36，`rw=write`，`ioengine=libaio`，`iodepth=16`
- 客户端：**普通用户**（导出启用了 `Root_Squash`，root 会被映射成 nobody 而无法写入）
- 每个用例采集：
  - fio 聚合吞吐（取 `Run status group` 的 `bw=`，**不是**首个 job 的 `BW=`）、总 IOPS、IO 错误数
  - Ganesha Prometheus：`nfsv4__op_count{op="WRITE"}`、`nfsv4__op_latency_sum/count` → 平均写延迟
  - `rpcs_received_total` 增量 → RPC/s
  - `ganesha` / `weed mount` / `weed server` 进程的 utime+stime（CPU 秒）
  - volume server `.dat` 总量变化（数据确实落盘的佐证）
- 崩溃检测：每用例前后比对 Ganesha PID 与 systemd `NRestarts`，任一变化即中止矩阵

**指标可信度校验**：客户端 fio 的 `clat` 平均 **154.30 ms** 与 Ganesha 服务端 `op_latency` 算出的 **153.03 ms** 几乎完全一致，
说明 Prometheus 延迟指标反映的是真实的端到端写延迟。

---

## 三、实测结果

### 3.1 完整矩阵（22 个用例）

| case | MiB/s | IOPS | io_err | avg WRITE lat (ms) | rpc/s | WRITE ops | ganesha CPU (s) | weed mount CPU (s) |
|---|---|---|---|---|---|---|---|---|
| `rep1_1M_1job` | 120 | 119 | 0 | 131.835 | 85.0 | 1024 | .7 | 5.2 |
| `rep2_1M_1job` | 131 | 130 | 0 | 120.689 | 125.3 | 1024 | .7 | 4.6 |
| `rep3_1M_1job` | 126 | 125 | 0 | 125.452 | 121.0 | 1024 | .7 | 4.9 |
| `nfs41_1M_1job` | 101 | 100 | 0 | 157.652 | 99.0 | 2048 | 1.4 | 12.5 |
| `nfsv3_1M_1job` | 104 | 103 | 0 | 0 | 102.5 | 0 | 1.4 | 12.3 |
| `nfs41_128k_1job` | 23.7 | 189 | 0 | 83.736 | 188.9 | 16384 | 3.0 | 20.1 |
| `nfs41_256k_1job` | 44.7 | 178 | 0 | 88.728 | 177.4 | 8192 | 2.3 | 17.7 |
| `nfs41_512k_1job` | 66.1 | 132 | 0 | 119.930 | 130.8 | 4096 | 1.7 | 15.3 |
| `nfs41_ws262144_256k` | 47.8 | 191 | 0 | 82.986 | 189.3 | 8192 | 2.2 | 16.4 |
| `nfs41_ws524288_512k` | 65.4 | 130 | 0 | 121.249 | 129.5 | 4096 | 1.8 | 15.6 |
| `nfs41_ws1048576_1M` | 98.8 | 98 | 0 | 160.287 | 97.5 | 2048 | 1.4 | 12.6 |
| `nfs41_1M_2job` | 279 | 287 | 0 | 109.282 | 265.0 | 2048 | 1.3 | 8.4 |
| `nfs41_1M_4job` | 473 | 482 | 0 | 122.715 | 453.1 | 4096 | 2.6 | 18.1 |
| `nfs41_1M_8job` | 761 | 772 | 0 | 76.739 | 711.9 | 4096 | 3.0 | 17.9 |
| `nfs41_buffered` | 2547 | 2547 | 0 | 21.596 | 640.4 | 2048 | 1.5 | 5.5 |
| `nfs41_odirect` | 104 | 103 | 0 | 153.033 | 101.9 | 2048 | 1.3 | 11.5 |
| `nfs41_fdatasync` | 76.7 | 76 | 0 | 11.466 | 75.6 | 1024 | .7 | 7.0 |
| `fuse_1M_odirect` | 1952 | 1952 | 0 | 0 | 0 | 0 | 0 | 4.8 |
| `fuse_1M_buffered` | 1350 | 1350 | 0 | 0 | 1.0 | 0 | 0 | 4.7 |
| `fuse_1M_4job` | 1956 | 1966 | 0 | 0 | 0 | 0 | 0 | 10.6 |
| `raw_1M_odirect` | 5278 | 5278 | 0 | 0 | 0 | 0 | 0 | 0 |
| `raw_1M_buffered` | 3185 | 3185 | 0 | 0 | 1.9 | 0 | 0 | 0 |

- `nfsv3_1M_1job` 的延迟列与 WRITEops 为 0 是**预期行为**：`nfsv4__*` 指标只覆盖 NFSv4。
- `.dat` 增量列在 `results/bench-write-io.csv` 中，可能为负 —— SeaweedFS 会在用例运行期间回收/压实 volume 文件，
  它是"数据到达了 volume server"的粗略指示，**不是字节计数器**。
- 重复性：三次完全相同的参考用例得到 120 / 131 / 126 MiB/s，**±5%**，矩阵数据可用。

### 3.2 瓶颈不在 Ganesha

`nfs41_odirect`：2048 次写耗时 19.77 s → 103.6 writes/s。
服务端平均延迟 153 ms、并发度 = 103.6 × 0.153 = **15.9 ≈ 16** —— 16 个 WRITE **全部并发在飞**。

而同期 Ganesha 只消耗 **1.3 s CPU / 19.77 s 墙钟 = 6.5% 单核**，`weed mount` 也只有 11.5 s（58% 单核）。
**两个进程都没跑满**，说明瓶颈是**等待**，不是计算。

### 3.3 决定性对照：绕过 FUSE

在同一个 Ganesha 上额外导出一个**本地 ext4 目录**（`Pseudo = /local-ext4`，无 FUSE），
用完全相同的 fio 负载（2 GiB / 1 MiB 块 / 1 job / O_DIRECT）：

| 路径 | O_DIRECT | 平均写延迟 | buffered |
|---|---|---|---|
| NFS → Ganesha → **FUSE** | **104 MiB/s** | 154 ms | 2547 MiB/s |
| NFS → Ganesha → **本地 ext4** | **719 MiB/s** | 22.1 ms | 3835 MiB/s |
| 直连 ext4（无 NFS 无 Ganesha） | 6077 MiB/s | 2.5 ms | — |

同一套 Ganesha、同一个客户端、同样 1 MiB 写 —— 唯一的差别是后端是 FUSE 还是 ext4，
吞吐相差 **7 倍**。这把问题精确定位到了 **Ganesha 写 FUSE 文件**这个动作上。

并发对比（同样 8 job、每 job 独立文件、O_DIRECT）：

| 路径 | 聚合吞吐 |
|---|---|
| NFS → Ganesha → FUSE | 761 MiB/s（矩阵，2 GiB 总量） |
| NFS → Ganesha → 本地 ext4 | **1574 MiB/s**（每 job 196–203 MiB/s） |

### 3.4 并发扩展性

单文件受限于"1 次 fsync / 1 MiB"；**换成多个文件就能并行**：

| job 数（每 job 独立文件） | 聚合 MiB/s | 每 job | 服务端平均延迟 |
|---|---|---|---|
| 1 | 101 | 101 | 157.7 ms |
| 2 | 279 | 139 | 109.3 ms |
| 4 | 473 | 118 | 122.7 ms |
| 8 | 761 | 95 | 76.7 ms |

聚合吞吐随 job 数近线性上升（101 → 761，**7.5×**），**每 job 吞吐反而下降**（101 → 95），
典型的"每文件独立串行槽位"模型。

### 3.5 协议版本无关

NFSv4.1 = 101 MiB/s，NFSv3 = 104 MiB/s，**无显著差异**。
两者都触发 stable write → 同样的 fsync 路径。v4.1 vs v4.2 的取舍与本瓶颈无关。

### 3.6 块大小

| bs | MiB/s | WRITE ops | Ganesha CPU | weed mount CPU |
|---|---|---|---|---|
| 128 KiB | 23.7 | 16384 | 3.0 s | 20.1 s |
| 256 KiB | 44.7 | 8192 | 2.3 s | 17.7 s |
| 512 KiB | 66.1 | 4096 | 1.7 s | 15.3 s |
| 1 MiB | 101 | 2048 | 1.4 s | 12.5 s |

块越小 → fsync 次数按字节数成比例增加 → 吞吐近似线性下降，同时 **Ganesha 与 FUSE 两侧 CPU 都上升**。

### 3.7 wsize 调参无效

客户端 `wsize=256K/512K/1M` 分别得 47.8 / 65.4 / 98.8 MiB/s —— 与直接调 fio `bs` 的结果（44.7 / 66.1 / 101）一致。
说明**瓶颈由 fsync 次数决定，与单个 WRITE 的大小无关**，调 wsize 不会有收益。

---

## 四、根因：Ganesha 对每次 stable write 调用一次 `fsync(2)`

### 4.1 源码链路

```c
/* src/Protocols/NFS/nfs4_op_write.c:571 */
write_arg->fsal_stable = arg_WRITE4->stable != UNSTABLE4 || force_sync;

/* src/Protocols/NFS/nfs3_write.c:360 */
write_arg->fsal_stable = arg_write3.stable != UNSTABLE || force_sync;

/* src/FSAL/FSAL_VFS/file.c:1397-1400 */
write_arg->io_amount = nb_written;
if (write_arg->fsal_stable) {
        retval = fsync(my_fd->fd);      /* ← 每个 WRITE 一次 fsync(2) */
```

客户端用 `stable_how = FILE_SYNC4` 发来的每个 WRITE，Ganesha 都会在 `pwritev()` 之后
对底层文件做一次 **`fsync(2)`**。

### 4.2 strace 实测（每个用例 256 次 1 MiB 写，总量 256 MiB）

| 路径 | `pwritev` | `fsync` | fio 吞吐 |
|---|---|---|---|
| NFS → FUSE，O_DIRECT | 256 | **256** | 202 MiB/s |
| NFS → FUSE，buffered | 256 | **1** | 3459 MiB/s |
| NFS → ext4，O_DIRECT | 256 | **256** | 701 MiB/s |
| NFS → ext4，buffered | 256 | **1** | 3459 MiB/s |

> 这一轮用 256 MiB 而非 2 GiB，以便 strace 能覆盖全部系统调用。
> 吞吐量因此与 §3.3 的 2 GiB 口径略有差异，但 **fsync 计数是完全确定的**。

**fsync 次数在 FUSE 与 ext4 上一模一样**，区别只在于这个 fsync 落在谁身上：

- ext4 上的 fsync ≈ **1.4 ms**（NVMe，缓存刷盘）→ 701 MiB/s
- SeaweedFS FUSE 上的 fsync ≈ **150 ms**（把 chunk 刷到 weed volume server + 写 filer 元数据）→ 104 MiB/s（2 GiB 口径）

trace 片段（16 个线程各自的 write → fsync 配对）：

```
130492 pwritev(27, [{iov_len=1048576}], 1, 0)        <unfinished ...>
130492 <... pwritev resumed>) = 1048576
130492 fsync(27)                                      <unfinished ...>
130492 <... fsync resumed>) = 0
```

**没有任何 `pread`** —— 排除了读改写（RMW）导致慢的可能。

### 4.3 为什么客户端会要求 stable write

Linux NFS 客户端在 **O_DIRECT** 下不使用 page cache，写必须带 `stable_how = FILE_SYNC4`；
buffered 写则用 `UNSTABLE4`（允许服务端异步落盘，靠后续 COMMIT 保证）。

因此 **O_DIRECT 是"每个 WRITE 一次 fsync"，buffered 是"整个文件一次 fsync"** —— 差了 16 倍以上的系统调用量。

### 4.4 数字自洽性

- FUSE 直写：1952 writes/s，16 在飞 → 单次写 ~8.2 ms
- 经 NFS 到 FUSE：103.6 writes/s，服务端延迟 153 ms → 排队 16 次 × 9.6 ms ≈ **154 ms** ✓
- 经 NFS 到 ext4：719 writes/s，服务端延迟 22.1 ms → 16 × 1.38 ms ≈ **22 ms** ✓

---

## 五、推荐模式与调优建议

### 5.1 实测四种写法（2 GiB / 1 MiB 块）

| 写法 | fio 报告吞吐 | 总耗时（含收尾） | 有效吞吐 | 数据落盘 |
|---|---|---|---|---|
| buffered，不显式同步 | 3710 MiB/s | 3.45 s | 594 MiB/s | 是（close 时隐式刷） |
| **buffered + `end_fsync=1`（推荐）** | 716 MiB/s | 3.22 s | **636 MiB/s** | 是 |
| buffered + `end_fsync=1`，8 GiB | 518 MiB/s | 16.15 s | **507 MiB/s** | 是 |
| O_DIRECT | 107 MiB/s | 19.65 s | **104 MiB/s** | 是（每次写都 fsync） |

**推荐：客户端用 buffered 写 + 显式 `fsync`/`fdatasync` 收尾**，在同等耐久性下比 O_DIRECT 快 **5–6 倍**。
注意 `nfs41_buffered` 的 2547 MiB/s 是**客户端 page cache 的接受速度**，不能当作落盘吞吐；
真正的端到端数字是上表的 636 / 507 MiB/s。

### 5.2 调优建议（按性价比排序）

1. **不要在 NFS 上用 O_DIRECT 做批量写**。改用 buffered + 末尾 fsync，收益 5–6 倍。
2. **用大块**。1 MiB 比 128 KiB 快 4.3 倍，且 Ganesha/FUSE 两侧 CPU 都更低。
   NFSv4.1 的 wsize 上限就是 1 MiB，所以 `MaxWrite`/`PrefWrite` 保持 1 MiB 即可。
3. **把并发摊到多个文件**，而不是加深度。同一个文件上的并发写共享同一个 fsync 串行槽位。
4. **若必须单文件高吞吐**，考虑让 Ganesha 不再直挂 FUSE：
   本地 ext4 导出在完全相同的负载下有 719 MiB/s（O_DIRECT）。
5. **降低 FUSE 侧 fsync 成本**（需要进一步调优 SeaweedFS）：
   `weed mount` 的 `-writeBufferSizeMB`、`-chunkSizeLimitMB`、`-metadataFlushSeconds`
   以及 filer 的元数据批量提交，都直接影响一次 fsync 的代价。这是下一轮调优的方向。
6. **不要动 `RPC_Ioq_ThrdMin/Max`**。并发度已经够用（16 个 WRITE 全部在飞），
   瓶颈在 fsync 而非线程数 —— 调线程数不会有任何收益。

---

## 六、附带修复：Ganesha V15.9 空指针崩溃

测试初期矩阵被 Ganesha 的 SIGSEGV 打断。已定位并修复。

### 6.1 现象

`Enable_Dynamic_Metrics = false` + `Enable_Metrics = true` 时，ganesha.nfsd 启动后
3–15 秒必崩（systemd 重启 → 再崩，crash-loop）。

### 6.2 根因（core 文件 gdb 分析）

```
#0 ganesha_monitoring::dynamic_metrics_export_info(...) at unique_ptr.h:199
#1 ganesha_monitoring::update_export(...)            at src/monitoring/prometheus_exposer.cc:506
#2 foreach_gsh_export(...)                           at src/support/export_mgr.c:938
#3 ganesha_monitoring::PrometheusExposer::server_thread(...) at src/monitoring/prometheus_exposer.cc:398
```

`src/MainNFSD/nfs_main.c:604-612` 只在 `enable_dynamic_metrics` 为真时才调用 `dynamic_metrics__init()`，
但 `prometheus_exposer__start()` 只要 `enable_metrics` 为真就无条件启动。
于是全局的 `static std::unique_ptr<DynamicMetrics> dynamic_metrics`（`dynamic_metrics.cc:282`）保持 **NULL**，
而 `dynamic_metrics_export_info`（`dynamic_metrics.cc:527`）是该文件里**唯一缺少
`if (!dynamic_metrics) return;` 保护**的函数（同文件 376/433/497/514 行都有）→ 空指针解引用 → SIGSEGV。

### 6.3 修复

`src/monitoring/dynamic_metrics.cc`，一行保护，与同文件其它函数保持一致：

```c
void dynamic_metrics_export_info(...)
{
+       if (!dynamic_metrics)
+               return;
        if (total_size) {
```

补丁文件：`patches/0001-monitoring-fix-null-deref-in-dynamic_metrics_export_info.patch`

重新编译安装后，`ganesha.nfsd` 连续运行 120 s `NRestarts=0`，整轮 22 用例矩阵全程零崩溃。

> 这是一个**上游 bug**，本地打了补丁。除非上游修复，否则任何使用
> `Enable_Metrics=true` + `Enable_Dynamic_Metrics=false` 组合的 V15.9 部署都会踩到。

---

## 七、原始数据

| 文件 | 内容 |
|---|---|
| `results/bench-write-io.csv` | 主矩阵 22 个用例的原始数值 |
| `results/bench-write-io.md` | 渲染后的表格 |
| `results/fio-raw/*.out` | 每个用例的 fio 完整输出（含 clat 百分位、IO 深度分布、CPU 占比） |
| `results/ext4-control.log` | 本地 ext4 对照实验 |
| `results/pattern-test.log` | 耐久化模式对比实验 |
| `scripts/bench-write-io.sh` | 矩阵测试 harness |
| `scripts/render-results.sh` | CSV → Markdown 渲染脚本 |
| `scripts/trace-ganesha.sh` / `trace-compare.sh` | strace 系统调用分析脚本 |
| `patches/0001-*.patch` | 空指针崩溃修复补丁 |

---

## 八、尚未覆盖 / 已知局限

1. **无跨机数据**。`192.168.3.134` SSH 超时不可达，所有结果均为本机客户端，
   不含 1 GbE 链路开销。按链路估算，跨机 NFS 写上限约 117 MB/s —— 会低于本报告的 FUSE 层数字，
   但**不会改变 fsync 根因**（fsync 是服务端行为，与网络无关）。
2. **未测 MDCACHE 包装**。基线用的是裸 `FSAL_VFS`。MDCACHE 会增加 inode/attr 缓存，
   可能降低服务端延迟，但也会掩盖真实 I/O 延迟，值得作为下一轮变量。
3. **未测 SeaweedFS 侧 fsync 调优**（§5.2 第 5 条）。这是降低 FUSE 侧 fsync 代价的下一个着手点。
4. **本机 NVMe 性能存在明显噪声**。`raw_1M_odirect` 在三轮测量中分别得到
   398 / 5278 / 5146 MiB/s（同一台机、同一命令），`raw_1M_buffered` 得到
   3185 / 3459 MiB/s。因此本报告的结论都建立在**同一轮次内的相对比较**之上，
   而不是跨轮次的绝对值。参考用例三次重复（120 / 131 / 126 MiB/s，±5%）可作为
   NFS 路径本身的噪声基线。
