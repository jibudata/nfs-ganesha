# 四个问题的实测回答

**日期**：2026-11-16　**主机**：`ys1000@192.168.3.146`（16 vCPU / 62 GiB RAM / NVMe）
**被测链路**：NFS client → `ganesha.nfsd` V15.9 (FSAL_VFS) → `fuse.seaweedfs` → weed filer → weed volume server → NVMe
**数据来源**：`results/final-bench.csv`（脚本 `scripts/final-bench.sh`）

> ⚠️ 客户端与服务端**同机**，NFS 走本机 br0，不经 1 GbE 物理网卡，因此**不含网络开销**。
> 宿主机上还跑着 3 个 KVM 虚机（合计约 130% CPU），绝对值偏低，**同窗口内的相对比较有效**。

---

## 0. 先说一个必须交代的修正：上一轮的块大小结论是在"挂载僵死"状态下测的

这一轮开始时我发现：**经 NFS 的写全部没有到达 volume server**——文件大小正确、客户端收到成功、
`pwritev()` 返回满字节、`fsync()` 返回 0，但 volume 的 `.dat` 一个字节不涨，filer 里也没有条目。

顺着这条线定位到：

| 时刻 | 事件 |
|---|---|
| 11:10:50 | 旧 Ganesha 实例（tgid 199441）被 systemd 停止时**卡死在 FUSE 写路径**上，dmesg 留下 hung task：<br>`fuse_cache_write_iter` → `rwsem_down_write_slowpath` → `down_write`（等 FUSE inode 的写锁） |
| 11:10–11:38 | 三套 FUSE 挂载进入僵死态。**直写 FUSE 挂载点正常落盘**（volume CPU 337t、`.dat` +1024 MiB），**经 NFS 写则全部被内核接受但数据消失** |
| 11:38 | `scripts/recover-fuse.sh`：lazy umount 三套 FUSE → 等 `/proc/mounts` 消失 → 重启 mount 服务 → 重启 Ganesha |
| 11:38+ | 恢复。NFS 的 O_DIRECT / buffered+fsync / buffered 三种写法**全部在 2 秒内落盘 64 MiB** |

**结论一（运维价值最高）：Ganesha 没有写超时，FUSE 挂载僵死时它会把写"成功"返回给客户端，数据静默丢失。**
这是比"客户端超时"严重得多的问题，也是下面第 2 问的直接依据。

**结论二：上一轮的块大小数据作废。** 当时测到的"512k→493、1M→861、4M→1759、8M→2032 MiB/s"（4.1× 差距）
测的是**僵死挂载下"数据被 RAM 写缓冲吸收"的假象**——大 write() 只是让 Ganesha 的 syscall 更省事，
并没有体现真实的 fsync 重叠。本轮在健康状态上重测，并**给每个用例加了"字节必须真的落到 volume server"的校验**
（`landed_mib` 列），结论见下。

---

## 1. 写块大小应该测哪些？

### 1.1 协议层的硬约束（先排除伪问题）

`wsize=1048576` ⇒ **NFS 协议层发出的每个 WRITE 恒为 1 MiB**。fio 的 `bs` 超过 wsize 时，
只是客户端 `write()` 更大，内核仍拆成多个 1 MiB 的 NFS WRITE。所以"服务端协商更大 wsize"这条路是死的。

### 1.2 实测（512 MiB/用例，wsize=1 MiB，fallocate=none，逐用例校验落盘）

| 层 | 块大小 | 吞吐 | 客户端 clat | Ganesha 写延迟 | 落盘校验 |
|---|---|---|---|---|---|
| NFS | 512k | **818 MiB/s** | 1.67 ms | 11.46 ms | 512/512 MiB ✓ |
| NFS | 1M | **697 MiB/s** | 4.52 ms | 13.68 ms | 512/512 ✓ |
| NFS | 4M | **737 MiB/s** | 15.77 ms | 13.51 ms | 512/512 ✓ |
| NFS | 8M | **779 MiB/s** | 29.29 ms | 12.90 ms | 512/512 ✓ |
| NFS | 1M **O_DIRECT** | **152 MiB/s** | 104.65 ms | 102.82 ms | 512/512 ✓ |
| NFS | 8M **O_DIRECT** | **630 MiB/s** | 199.99 ms | 57.81 ms | 512/512 ✓ |
| NFS | 1M × 8 job（8 个文件） | **1145 MiB/s** | 8.94 ms | 0.71 ms | 514/512 ✓ |
| FUSE | 1M | 1932 MiB/s | 7.63 ms | – | 512/512 ✓ |
| FUSE | 4M | 2008 MiB/s | 28.22 ms | – | 512/512 ✓ |
| FUSE | 8M | 2188 MiB/s | 48.61 ms | – | 512/512 ✓ |

### 1.3 三条结论

1. **buffered 路径：块大小基本无关**（697–818 MiB/s，±8%，无单调性）。
   因为 buffered 写全程只有**末尾一次 fsync**，没有 per-WRITE fsync，块大小不影响同步次数。
2. **O_DIRECT 路径：块大小是 4.1× 的杠杆**（1M→152 MiB/s，8M→630 MiB/s）。
   O_DIRECT 让客户端的每个 WRITE 都是 stable write ⇒ Ganesha 每个 WRITE 调一次 `fsync(2)`
   （`src/FSAL/FSAL_VFS/file.c:1399`）。块大到 8 MiB 时，多个 WRITE 的 fsync 可以重叠；
   1 MiB 时则被完全串行化（Ganesha 写延迟 102.8 ms ≈ 整个 clat）。
   **这才是 fsync 重叠效应真正成立的地方**，上一轮把它错误地归因到了 buffered 路径。
3. **并发比块大小更能提吞吐**：8 job × 1M（8 个不同文件）= 1145 MiB/s，比单文件 1M 的 697 高 **1.64×**。
   因为每个文件有独立的 fsync 串行槽位。

### 1.4 推荐测试矩阵

| 层 | 测哪些块 | 为什么 |
|---|---|---|
| **NFS（主战场）** | **512K / 1M / 4M / 8M**，wsize 固定 1 MiB | 覆盖 O_DIRECT 下 4.1× 的 fsync 串行化差异；buffered 下用来证明"不敏感"，两边都要有 |
| NFS | 1M vs 8M 各配 **O_DIRECT / buffered+end_fsync** 两种 | 两种写模式的 fsync 语义完全不同，必须成对测 |
| NFS | **8 job × 1M**（并发维度） | 并发是独立于块大小的第二个杠杆 |
| **FUSE** | **只测 1M / 4M** | 1M→1932、4M→2008、8M→2188 MiB/s，8M 只比 1M 高 13%，而 chunk 上限是 2 MiB（`chunkSizeLimitMB=2`），8M 无独立价值 |

**不要在 FUSE 层测 512K**（chunk 上限 2 MiB，512K 必然产生碎片 chunk 且无收益）。

---

## 2. NFS 挂载参数？用 `hard`, `sync` 吗？

### 2.1 结论：**保持 `hard` + `sync`，不要改成 `soft`/`softerr`**

`man 5 nfs` 原文：

> A so-called 'soft' timeout can cause **silent data corruption** in certain cases. As such, use the
> soft or softerr option only when client responsiveness is more important than data integrity.
> Using NFS over TCP or increasing the value of the retrans option may mitigate some of the risks.

本链路已经是 TCP（`proto=tcp`），soft 的风险被部分缓解，但**这里没有任何理由用 soft**：

- 本实验台的真实风险在**服务端**（Ganesha 无写超时、FUSE 可僵死、SeaweedFS master 的 vacuum 会打断上传）。
  这些风险 `soft` 一个都解决不了——它只是让客户端提前放弃并返回 EIO，把**静默丢失**换成**显式报错**。
- 第 0 节那个案例说明：客户端 hard mount 无限重试、服务端却"成功但丢数据"，这才是真正该修的地方。
  用 soft 换来的"响应性"是拿数据完整性去换，而且换来的还不是真响应性（服务端仍然卡死）。

`sync` 是默认（挂载参数里没有 `async` 就是 sync），NFSv4 下不要加 `async`——它会削弱写语义。

### 2.2 推荐挂载参数

```
mount -t nfs \
  -o vers=4.1,proto=tcp, \
     rsize=1048576,wsize=1048576, \
     hard,timeo=600,retrans=2 \
  192.168.3.146:/seaweedfs <mountpoint>
```

| 参数 | 建议 | 理由 |
|---|---|---|
| `hard` | **必须** | 见上。`soft`/`softerr` 有静默数据损坏风险 |
| `sync` | **必须**（默认） | 不要加 `async` |
| `timeo=600` | 保持（60 s） | TCP 下 `timeo` 是"重传等待窗口"的量级，不是超时上限；太小会在慢 fsync 下误杀 |
| `retrans=2` | 保持 | 同上 |
| `rsize/wsize=1048576` | 保持 | 已等于协议上限；**服务端侧调这个没用**（实测 wsize 256K/512K/1M 对应 47.8/65.4/98.8 MiB/s，与直接调 fio bs 一致） |
| `vers=4.1` | 建议显式钉住 | V15.9 默认放开 v4.2（`minor_versions` 是位掩码，默认全开）。要只跑 v4.1 就写 `NFSv4 { minor_versions = 0,1; }` |
| `nconnect=N` | **多线程客户端可加** | 每条 TCP 连接独立，可绕开单连接窗口限制。代价是 Ganesha 每连接的 1 MiB 收发缓冲 × N，以及服务端线程数 |
| `actimeo=` | 元数据密集负载再调 | 写吞吐实验不要动 |

### 2.3 真正该在服务端做的三件事

1. **给 Ganesha 加写超时/熔断**（当前完全没有）——FUSE 卡住时它会无限阻塞。
2. **所有 `weed master` 加 `-vacuumIntervalSeconds=86400`**——默认 840 s 的 vacuum 扫描会让 volume
   压缩并打断正在上传的 chunk，实测能把整条 NFS 写路径卡死 >15 分钟。
3. **监控"写成功但 volume `.dat` 不增长"**——这是挂载僵死的唯一可靠信号，见第 5 节。

---

## 3. 内存与 CPU 推荐配置

### 3.1 CPU：实测每 GiB 写吞吐消耗的 CPU 秒

| 用例 | ganesha | weed mount | weed server | weed filer | weed master | **合计** | **CPU-s/GiB** |
|---|---|---|---|---|---|---|---|
| NFS 512k buffered | 0.80 | 2.38 | 2.80 | 0.30 | 0.10 | 3.19 | **6.38** |
| NFS 1M buffered | 0.78 | 2.40 | 2.96 | 0.38 | 0.14 | 3.33 | **6.66** |
| NFS 4M buffered | 0.82 | 2.44 | 2.94 | 0.32 | 0.12 | 3.32 | **6.64** |
| NFS 8M buffered | 0.80 | 2.36 | 2.90 | 0.32 | 0.12 | 3.25 | **6.50** |
| NFS 1M O_DIRECT | 0.80 | 4.00 | 3.46 | 2.20 | 0.20 | 5.33 | **10.66** |
| NFS 8M O_DIRECT | 0.84 | 3.02 | 3.68 | 0.46 | 0.16 | 4.08 | **8.16** |
| NFS 1M × 8 job | 0.78 | 2.92 | 3.18 | 0.86 | 0.12 | 3.93 | **7.86** |
| FUSE 1M 直写 | 0.04 | 2.64 | 3.20 | 0.20 | 0.10 | 3.09 | **6.18** |
| FUSE 8M 直写 | 0.04 | 2.34 | 3.04 | 0.18 | 0.08 | 2.84 | **5.68** |

（单位：CPU-s / GiB 写入量；含写入 + chunk 上传 + 排空整个窗口）

**两条关键结论：**

- **Ganesha 只占 12% 的 CPU，SeaweedFS 侧（mount + volume）占 81%。**
  → **不要为 Ganesha 单独配核**。Ganesha 1 核 ≈ 1.25 GiB/s 的 RPC 处理能力，远高于它需要的 0.8 CPU-s/GiB。
  → 瓶颈在 SeaweedFS 的上传路径，核要加在那里。
- **buffered 与 O_DIRECT 的 CPU 成本差 1.3–1.7×**，因为 O_DIRECT 让每个 WRITE 都带一次 fsync。

### 3.2 CPU 配比公式

```
需要的核数 ≈ 目标写吞吐(GiB/s) × CPU-s/GiB × 1.3(余量)
```

| 目标 NFS 写吞吐 | buffered 路径 | O_DIRECT 路径 |
|---|---|---|
| 0.5 GiB/s | 4–5 核 | 6–8 核 |
| 1 GiB/s | 8–9 核 | 11–13 核 |
| 2 GiB/s | 16–18 核 | 23–26 核 |
| 4 GiB/s | 33–35 核 | 46–50 核 |

> 余量 1.3 覆盖：宿主机其它负载、volume compaction、filer/master 后台、元数据 IO。
> 本机 16 核实测在 1 GiB/s buffered 下 Ganesha 只占 0.8 核、整条链路约 6.5 核。

**并发不是免费的**：核数够了之后，多加 Ganesha 线程（`RPC_Ioq_ThrdMin/Max`）不再提升吞吐，
因为 16 个 WRITE 本来就全部并发在飞，瓶颈是等待而不是排队。

### 3.3 内存：实测 RSS + 各组件的固定开销

| 组件 | 实测 RSS（跑完一轮后） | 固定/可配开销 | 说明 |
|---|---|---|---|
| `weed mount` | 287 → **429 MB** | **`-writeBufferSizeMB=4096`（4 GB/挂载点）**<br>`-cacheCapacityMB=128`（元数据缓存） | **最大的内存项**。写缓冲装不满时 RSS 只有几百 MB，但上限是 4 GB |
| `weed filer` | 344 → **585 MB** | LevelDB（`-defaultStoreDir`） | 随元数据增长，务必放 NVMe |
| `weed master` | 105 → **113 MB** | 元数据目录 | 很稳定 |
| `weed server` | 183 → **207 MB** | volume 索引 `.idx` | 随 volume 数增长 |
| `ganesha.nfsd` | 208 → **356 MB** | MDCACHE inode 缓存 + 每连接 1 MiB 收发缓冲 | 随打开文件数/连接数增长；观测到 ~2 MB/活跃连接 |
| 内核 page cache | — | **RAM × dirty_ratio(默认 20%)** | NFS 客户端页缓存 + FUSE 挂载点页缓存**各一份**，最容易被低估的一块 |

### 3.4 内存配比公式

```
RAM ≈ 每 FUSE 挂载点 4.5 GB(写缓冲 4 + 元数据缓存 0.13 + 进程开销)
     + 1.0 GB (filer 0.6 + master 0.1 + volume 0.2)
     + RAM × 20% × 2 (客户端脏页 + FUSE 脏页, 按总量 40% 预留)
     + 每 NFS 客户端连接 2–4 MB
```

**推荐配置表：**

| 目标 | vCPU | RAM | 备注 |
|---|---|---|---|
| 1 GiB/s NFS 写（buffered） | **8–9 核** | **32 GB** | 单挂载点；RAM 的 40% 给脏页 |
| 1 GiB/s NFS 写（O_DIRECT） | 11–13 核 | 32 GB | O_DIRECT 不吃页缓存，脏页压力小，但 CPU 贵 1.5× |
| 2 GiB/s | 16–18 核 | **64 GB** | |
| 4 GiB/s | 34–36 核 | **128 GB** | 需要多套 volume server |

**每加一个 FUSE 挂载点：RAM +4.5 GB，CPU +约 3 核**（mount 进程本身 + 它的上传工作）。
多挂载点/多集群一定要提前把这笔账算进去。

**降内存的两个开关：**
- `-writeBufferSizeMB` 从 4096 调到 1024 → 每挂载点省 3 GB。代价是写缓冲更容易被填满，
  触发同步上传，吞吐会掉（实测 6 GiB 持续写时 HDD 档就是被设备带宽卡死的）。
- `-cacheCapacityMB` 从 128 调到 64 → 省 64 MB，收益小，优先级低。

---

## 4. 推荐的 Ganesha MDCACHE 设置

### 4.1 先纠正一个前提

**V15.9 里 MDCACHE 默认就在栈上**，VFS 是它的底层 FSAL——启动日志里的
`mdcache_fsal_create_export` 可以证实。所以"要不要加 MDCACHE"这个问题不成立，
真正的问题是"要不要调它的参数"。

### 4.2 V15.9 的默认值（`src/FSAL/Stackable_FSALs/FSAL_MDCACHE/mdcache_read_conf.c:57-109`）

| Token | 默认 | 含义 |
|---|---|---|
| `NParts` | 7 | MDCACHE 树的分区数（锁分片） |
| `Cache_Size` | 32633 | **每分区**的哈希表大小 ⇒ 总条目 ≈ 7 × 32633 ≈ 228k |
| `Dir_Chunk` | **128** | 目录 AVL chunk 大小（`MDCACHE_AVL_CHUNK_DEFAULT`） |
| `Dir_Chunk_Enable` | true | |
| `Entries_HWMark` | 100000 | 条目 LRU 高水位 |
| `Entries_Release_Size` | 100 | 每次释放条目数 |
| `Chunks_HWMark` / `Chunks_LWMark` | 1000 / 1000 | |
| `LRU_Run_Interval` | 90 (s) | LRU 清理周期 |
| `Cache_FDs` | true | 缓存文件描述符 |
| `Close_Fast` | false | |
| `Open_FD_Limit` | 0（不限） | |
| `FD_Limit_Percent` | 99 | |
| `FD_HWMark_Percent` | 90 | |
| `FD_LWMark_Percent` | 50 | |
| `Reaper_Work` / `Reaper_Work_Per_Lane` | 0 / 50 | |
| `Num_LRU_Lanes` / `Num_Chunk_LRU_Lanes` | `LRU_DEFAULT_N_Q_LANES` | |
| `Biggest_Window` / `Required_Progress` / `Futility_Count` | 40 / 5 / 8 | 目录遍历并行度 |
| `Dirmap_HWMark` | 10000 | |
| `Files_Delegatable_Percent` | 90 | |
| `Use_Getattr_Directory_Invalidation` | false | |
| `Use_Cached_Owner_On_Owner_Override` | true | |

### 4.3 从你给的 GPFS 参考配置映射过来

| GPFS 参考项 | → V15.9 MDCACHE | 动作 |
|---|---|---|
| `MDCACHE{dir_chunk=128}` | `Dir_Chunk = 128` | **已经是默认，不用改** |
| `lru_run_interval=90` | `LRU_Run_Interval = 90` | **已经是默认，不用改** |
| `CacheInode{fd_hwmark_percent=60}` | `FD_HWMark_Percent = 60` | **改**（默认 90 → 60） |
| `CacheInode{fd_lwmark_percent=0}` | `FD_LWMark_Percent = 0` | **改**（默认 50 → 0） |
| `CacheInode{fd_limit_percent=90}` | `FD_Limit_Percent = 90` | **改**（默认 99 → 90） |
| `CacheInode{entries_hwmark=1500000}` | `Entries_HWMark = 1500000` | **改**（默认 100000 → 1500000，注意内存） |

### 4.4 我的建议

**基线保持裸 `FSAL_VFS`（VFS 作为 MDCACHE 的底层 FSAL，但不要为 MDCACHE 单独开一组参数）**，
把 MDCACHE 当作一个**独立变量**单独测。原因：

1. **MDCACHE 不解决本实验台的写瓶颈。** 它缓存 inode/attr/dentry，**不缓存数据**。
   本实验台的瓶颈是"每个 stable write 一次 fsync"（`file.c:1399`）和 SeaweedFS 的 chunk 上传，
   两者都在 MDCACHE 之下。
2. **MDCACHE 会掩盖真实 I/O 延迟。** attr 命中后客户端看到的 GETATTR 延迟是内存值，
   用它做的延迟 SLO 报告会好看得离谱，但底层 ext4/FUSE 的真实延迟被藏起来了。
   性能实验室尤其不该开。
3. **它吃内存。** `Entries_HWMark=1500000` 意味着最多 150 万个 inode 常驻，
   按每条 ~200 B 估就是 ~300 MB；加上 MDCACHE 的分片哈希表，**每个 Ganesha 实例要多留几百 MB**。
   在 32 GB 的机器上做 1 GiB/s 写压测时，这笔账要算进去。

**如果确实要开（生产环境元数据密集、目录操作多），用这一组：**

```
MDCACHE {
    FD_HWMark_Percent = 60;     # 降：不要让 Ganesha 占满系统 fd
    FD_LWMark_Percent  = 0;     # 低水位清到 0，配合上面的高水位做硬上限
    FD_Limit_Percent   = 90;    # 给其它进程留 10% 的 fd
    Entries_HWMark     = 1500000;  # 仅在 inode 数确实超 10 万时再调
    Dir_Chunk          = 128;   # 已是默认，显式写出来是为了可读性
    LRU_Run_Interval   = 90;    # 已是默认
    Close_Fast         = false; # 已是默认；改成 true 会让每次操作都开关 fd，抬高延迟
}
```

**另外两个与本实验台直接相关的 MDCACHE 观察：**

- `NParts = 7`：这是 MDCACHE 树的分区数（锁分片）。16 核机器上如果出现 inode 锁竞争，
  调到 16 或 32 是低风险的第一步（它只影响哈希分片，不改变语义）。
- `Use_Getattr_Directory_Invalidation = false`：SeaweedFS 后端的目录会变，
  开启它可以让 MDCACHE 用 GETATTR 而不是自己缓存来做失效判断，**对"文件由别的路径创建"的场景更安全**。
  本实验台里客户端和 Ganesha 在同机、文件都是 Ganesha 自己建的，所以保持 false 没问题。

---

## 5. 落地清单

| # | 动作 | 优先级 |
|---|---|---|
| 1 | 所有 `weed master` 加 `-vacuumIntervalSeconds=86400`（默认 840 s 的 vacuum 会打断 chunk 上传 → FUSE 阻塞 → Ganesha 阻塞 → 客户端无限重试）。**参数必须写进 systemd `ExecStart` 真正指向的启动脚本**，并让 `make-cluster.sh` 生成它 —— 2026-11-16 复查发现 cluster A 的 `master.sh` 和生成器都漏了它，一旦重启就退回 840 s。再叠加运行时开关 `weed shell -master=... → lock, volume.vacuum.disable, unlock`（重启后失效，所以两者都要） | **P0** |
| 2 | 给 Ganesha 加**写超时/熔断**（当前完全没有；FUSE 僵死时它无限阻塞且"成功"返回丢数据） | **P0** |
| 3 | 监控 volume `.dat` 的增长速率 vs NFS WRITE 速率；两者背离 = 挂载僵死**或导出已失效**。WRITE 速率取自 Prometheus：`http://192.168.3.146:32000/metrics`（远端节点用主机 IP，别用 `127.0.0.1`），抓取要 `curl -o file` 再解析 | **P0** |
| 4 | **重启 FUSE 挂载服务后必须重启 Ganesha**（`systemctl restart seaweedfs-mount*.service` 之后紧跟 `systemctl restart ganesha`）；否则导出静默失效：写成功、客户端无报错、字节全部丢失 | **P0** |
| 5 | 客户端保持 `hard` + `sync`；不要为了"响应性"改 `soft`/`softerr` | P1 |
| 6 | 客户端 fio/应用用 **≥8 MiB 块**（若走 O_DIRECT，收益 4.1×），或**多文件并发**（收益 1.64×）。**走 NFS 的 O_DIRECT 负载尤其要放大块**：1 MiB 时 NFS+Ganesha 前端吃掉整条路径的 **83%**，8 MiB 时降到 54%；buffered 负载不受影响（见 §6.2） | P1 |
| 7 | 按 §3.2/§3.4 配核与内存；`weed mount -writeBufferSizeMB` 是最大的一项 | P1 |
| 8 | MDCACHE 保持默认；确要调就用 §4.4 那一组，并把 MDCACHE 当独立变量测 | P2 |
| 9 | 所有 fio/应用在 FUSE 后端上用 **`fallocate=none`**；预分配在这个后端上不是免费的（见 §5.1） | P1 |

**僵死自愈脚本**：`scripts/recover-fuse.sh`（lazy umount → 等 `/proc/mounts` 消失 → 重启 mount → **重启 Ganesha** → 用真实落盘字节校验）。

**只读体检脚本**：`scripts/verify-exports.sh`（不动栈，只挂载、写 32 MiB 非零数据、核对 volume `.dat` 增量、卸载）。任何时候想知道"导出现在到底健康吗"，跑它就够了——它输出 `delta=32 MiB OK` 才算健康。

**测量前必跑的自检**：`scripts/check-vacuum-state.sh`。它查三层，任何一层不满足都会让 sweep
在压测窗口里打断上传：启动脚本有没有设 `-vacuumIntervalSeconds`（≥ 86400）、**运行中的进程**
命令行有没有带、master 有没有被 `volume.vacuum.disable` 关掉、以及关掉之后有没有又跑过 sweep。
输出 `result: PASS` 才允许开测。

**它不是只在崩溃后用**：`recover-fuse.sh` 是一套**顺序**，任何一次挂载服务重启之后都该走一遍。
Ganesha 只在启动时解析一次导出路径并持有该挂载的 dirfd；挂载被卸载重装后，这个 dirfd
仍指向**旧的、已分离的**挂载实例——写进去被内核页缓存接受、返回成功，而真正持有连接的
`weed mount` 进程已经没了，字节全部丢失。2026-11-16 实测复现：重启
`seaweedfs-mount.service` 后写 32 MiB，客户端报 "0.108 s, 310 MB/s"，volume `.dat`
增量 **0 MiB**。

这也解释了为什么当初那份"NVMe 1517 vs HDD 93 MiB/s"必须作废：产出它的
`final-sus.sh` 会重启 A2 挂载来清写缓冲，却没重启 Ganesha——1517 MiB/s 正是
"写进一个死挂载"的特征（没有 fsync、没有真实 I/O、什么也没落盘）。

### 5.2 导出失效的判别

`.dat` 不涨有两种成因，处置不同：

| 现象 | 成因 | 处置 |
|---|---|---|
| 写成功、客户端无报错、`.dat` 不涨；吞吐**异常高** | 导出指向已分离的旧挂载（挂载被重启过） | `systemctl restart ganesha`，或直接跑 `recover-fuse.sh` |
| 写阻塞/超时、`.dat` 不涨；吞吐**很低** | 挂载僵死（FUSE 写路径卡死） | `recover-fuse.sh`（lazy umount → 重挂 → 重启 Ganesha → 校验） |
| `df`/文件大小正常但 `.dat` 不涨 | 探针写了全零数据 | 探针改用 `/dev/urandom`（见 §5.1 与 `LAB-CONVENTIONS.md` R4a） |

判别第 1 种的方法：看 Ganesha 握着的 dirfd 指向哪个挂载实例——

```bash
GP=$(pgrep -x ganesha.nfsd | head -1)
ls -l /proc/$GP/fd 2>/dev/null | grep -E "seaweedfs.*mnt"
```

### 5.1 预分配（`fallocate` / `ftruncate`）在这个后端上的真实语义

fio 挂在大文件上时会出现 `Laying out IO file (1 file / 12288MiB)` 卡住，容易被误判成
"后端把预分配实现成了写零"。**实测结论相反**（95 秒长窗口，等待 4 GB 写缓冲排空）：

| 操作 | 调用返回 | volume `.dat` 增长 | mount RSS |
|---|---|---|---|
| `fallocate -l 4G` | 0 s | **+1 MiB** | 444 MB |
| `fallocate -l 12G` | 0 s | **0 MiB** | 444 → 167 MB |
| `dd` 4 GiB 真实零数据 | 3.12 s | **+4 MiB** | 296 MB |

**预分配不会写入任何真实零数据**（SeaweedFS 连"真实零数据 chunk"都只存引用）。
它的真实代价是**元数据**：

```
SeaweedFS FUSE:  truncate -s 4G  ->  st_size = 4 GiB, st_blocks = 8388608   （报告为全量已分配）
ext4:            truncate -s 4G  ->  st_size = 4 GiB, st_blocks = 0           （稀疏，什么都没预留）
```

即：`truncate` 到更大尺寸会让整个区间变成 filer LevelDB 里的 chunk 条目
（12 GiB @ `chunkSizeLimitMB=2` ≈ 6144 条），`st_blocks` 类的配额工具会**按整个文件大小多报**。

**且经 NFS 时行为不同**：`fallocate` **直接失败**（rc=1，文件保持 0 字节），`truncate` 成功并创建上述元数据。
所以 NFS 客户端侧的真正风险是 `truncate`，不是 `fallocate`。

**做法**：fio 一律 `fallocate=none`；应用不要在这个后端上预分配，改成"先写后扩"；
`weed mount` 侧用 `-chunkSizeLimitMB` 调大来减少元数据条目数。

---

## 6. 封装方式是不是瓶颈？NFS + Ganesha 前端值多少钱？

这一节回答两个问题：**把存储后端装进 Docker / Kubernetes 值不值**，以及
**NFS + Ganesha 这一层前端在写路径上占多少**。

### 6.1 三种封装：同一个负载，三条数据路径

Ganesha 和 FUSE 网关在三个臂里**完全相同**（都在宿主），唯一变量是存储后端：

```
裸机臂：    NFS 客户端 → Ganesha → FUSE(宿主) → filer(宿主) → volume(宿主 NVMe)
Docker 臂： NFS 客户端 → Ganesha → FUSE(宿主) → filer(容器) → volume(容器)
K8s 臂：    NFS 客户端 → Ganesha → FUSE(宿主) → filer(pod)  → volume(pod)
```

实测：3 轮交错、每轮轮转臂顺序、每个用例强制校验落盘、每个用例前后查三服务健康。
**36/36 用例全部落盘，零 void**（SIZE=128M，MiB/s 中位数）：

| case | 裸机 | Docker | Kubernetes | 极差(max/min) |
|---|---|---|---|---|
| buf1M（1M buffered） | 643 | 727 | 776 | +21% |
| buf8job（1M buffered × 8 job） | 1049 | 934 | 941 | +12% |
| odirect1M（1M O_DIRECT） | 205 | 218 | 229 | +12% |
| odirect8M（8M O_DIRECT） | 727 | 727 | 749 | +3% |

**结论：三条臂落在同一条噪声带内。** 极差最大的一格（buf1M，+21%）也只等于
同一用例在不同轮之间的抖动（裸机这一格本身就在 582..740 之间跑），
而 buf1M 这一格的 Ganesha WRITE 延迟中位数是 13.5 / 12.5 / 12.9 ms（裸机/Docker/K8s），
CPU-s/GiB 全部落在 6.4–8.6。

**⇒ 封装方式不是写路径瓶颈。** 把 SeaweedFS 装进容器或 Kubernetes **不花吞吐**，
换来的是部署与弹性的自由度。这条结论只在**存储面**成立；K8s 臂另有一份独立成本：
MetalLB 固定 IP、固定 `loadBalancerIP`、以及"客户端将来要用的那个地址必须是登记地址"
这一整套约束（`LAB-CONVENTIONS.md` R19–R23）。

### 6.2 第四形态：把前端拿掉，量存储路径本身

第四形态把 FUSE 网关**放进 pod**，fio 就在**同一个 pod** 里写它：

```
fio → FUSE(pod) → filer(pod) → volume(pod)      （没有 NFS，没有 Ganesha）
```

它不是"第四个点"，而是**同一系列去掉前端之后的样子**。K8s 臂与它写进**同一套
Kubernetes 存储面**、用**同一套 FUSE 网关配置**，两者之间差的**就是 NFS + Ganesha
前端的成本**：

| case | K8s 臂 + NFS/Ganesha | 第四形态（无前端） | 前端成本 | 每组数据集的中位数 |
|---|---|---|---|---|
| buf1M | 776 | 1055 | 1.36×（占路径 26%） | 1016 / 1094 |
| buf8job | 941 | 967 | 1.03×（占路径 3%） | 1000 / 934 |
| **odirect1M** | 229 | **1332** | **5.82×（占路径 83%）** | 1085 / 1580 |
| **odirect8M** | 749 | **1642** | **2.19×（占路径 54%）** | 1684 / 1561 |

（MiB/s；K8s 臂是 3 轮中位数，第四形态是**两组各 3 轮、共 6 轮的中位数**；
24 个用例全部落盘、零 void。最后一列是每组数据集各自的中位数，
用来显示这个结论不是被某一组数据带出来的。）

**两条结论：**

1. **buffered 写几乎不花前端的钱。** 8 job 并发时前端只占路径的 3%，单 job 也只占
   26%——因为聚合之后 fsync 被摊薄了。这和 §1.3「并发比块大小更能提吞吐」是同一件事的
   两面：并发既抬吞吐，也把前端的成本摊薄。

2. **O_DIRECT 写的前端成本高得离谱：1 MiB 块时前端吃掉整条路径的 83%。**
   原因在 §1.2 已经量过：O_DIRECT 的每个 WRITE 都是 stable write ⇒ 每个 WRITE
   一次 fsync（`file.c:1399`），1 MiB 时 fsync 完全串行。把块放大到 8 MiB 让多个
   fsync 重叠，前端成本立刻从 83% 降到 54%。

**⇒ 部署建议：走 NFS 的 O_DIRECT 负载，要么把块放大到 ≥8 MiB，要么放弃 O_DIRECT。**
这不是"XFS/SeaweedFS 谁更快"的问题，而是**协议层每个 WRITE 都要 fsync 一次**这件事
在 Ganesha 上被串行化了。buffered 负载不受影响。

### 6.3 这两条结论的适用边界（必须交代）

- 第四形态与三臂**不是同一个进程内交错**的：第四形态测了两遍
  （01:50–01:57 与 02:21–02:24），三臂测了一遍（01:58–02:10），同一台宿主、同一天、
  同一套 K8s 存储面，但**是两个中位数相减，不是受控 A/B**。因此只有**差距大的时候
  才发现得出来**：5.82× 是发现，1.03× 是噪声。
- **单轮不可信**：第四形态同一个用例跨轮最大抖到 2.09×（buf8job 的 631..1320 MiB/s）。
  所以每组 3 轮、再把两组 6 轮合并取中位数，并把每组各自的中位数一起列出来。
- 宿主只有 62 GiB RAM、swap 已占满，上面还跑着 3 台 KVM 虚机和 KIND 集群。
  **绝对吞吐只宜同窗口相对比较**，不要把这些数字当成容量规划依据。
- 第四形态的 fio 在容器里（Ubuntu 24.04 的 3.36 包），三臂的 fio 在宿主（自建的
  3.36）。**上游版本相同**，但不是同一个二进制；`build-image.sh` 会校验版本一致。

**怎么复现：**

```bash
ROUNDS=3 SIZE=128M CONC_SIZE=16M bash scripts/arm-compare.sh   # 三臂
ROUNDS=3 bash scripts/k8s-fuse-fio.sh                            # 第四形态
bash scripts/render-arm-compare.sh                               # 三臂表
bash scripts/render-front-end-cost.sh                            # 联合表
```

---

## 7. 原始数据

- `results/arm-compare-3arms.csv` —— 三臂对比 36 个用例（吞吐 / clat(ms) / Ganesha 写延迟 / 落盘校验 / 5 进程 CPU）
- `results/k8s-fuse-fio-inpod.csv` —— 第四形态**第一组** 12 个用例（吞吐 / clat(ms) / 落盘校验）
- `results/k8s-fuse-fio-inpod-run2.csv` —— 第四形态**第二组** 12 个用例（同上）；§6.2 的数字是**两组 24 例合并**后的中位数
- `results/final-bench.csv` —— 本轮全部 10 个用例（吞吐 / clat / Ganesha 写延迟 / 落盘校验 / 5 进程 CPU / RSS）
- `results/sustained-v2.csv` —— 6 GiB 持续写 NVMe vs HDD（**含 `landed_mib` 落盘校验**）
- `results/ssd-vs-hdd-sustained-VOID-dat_delta-was-0.csv` —— **作废**：早期持续写数据，`dat_delta_mib` 为 0（字节没落盘），保留作证据
- `results/blocksize.csv` —— 上一轮块大小数据（**注意：在僵死挂载上测得，已被本轮取代**）
- `results/timeline.csv` —— 每秒采样的 CPU/内存时间线
- `results/ssd-vs-hdd.csv` —— NVMe vs HDD 短写对照（`dat_delta` 已校验）
- `scripts/final-bench.sh` —— 本轮基准脚本（每个用例强制校验落盘）
- `scripts/recover-fuse.sh` —— 挂载僵死自愈 + 落盘校验
- `scripts/where-does-ganesha-write.sh` —— 定位 Ganesha 实际写入位置
- `scripts/arm-compare.sh` / `scripts/render-arm-compare.sh` —— 三臂对比矩阵与渲染
- `scripts/k8s-fuse-fio.sh` / `scripts/render-front-end-cost.sh` —— 第四形态矩阵与「前端成本」联合表
