# colima 参数组合矩阵(8 vCPU / 8 GiB,2026-11-19)

环境:colima VM(kind 单节点 `ganesha-fuse-ci`),K8s pod 臂单容器 Ganesha+FUSE,客户端 = VM 内核 NFS client(NodePort 32049,vers=4.1,wsize 1M,hard)。基线 pod 配置:CONCURRENT_WRITERS/READERS=32、WRITE_BUFFER_SIZE_MB=1024、RPC_Ioq_ThrdMax=32。严格串行协议:单 fio → 落盘校验 → 删测试文件 → 组间 `volume.vacuum -garbageThreshold=0.01`(57 GiB 死数据回收至 3.31 GiB)。

尺寸案例 1.5 GiB 落盘校验;随机写 4k/64k 为 time_based 180 s(64M 文件反复覆写,IOPS 为比较口径,landed>0 校验)。

## 结果

### chunk 扫描(writers=32 固定)

| 案例 | chunk 8 | chunk 4 | chunk 2 |
|---|---|---|---|
| buffer-1m (MiB/s) | 213 | 199 | 249 |
| odirect-1m (MiB/s) | 18.5 | 20.8 | 20.0 |
| randwrite 4k (IOPS) | **9372** | 4813 | 4332 |
| randwrite 64k (IOPS) | **1052** | 908 | 890 |

### FUSE writers 扫描(chunk=8 固定,buffer-1m)

| writers | 16 | 32 | 64 |
|---|---|---|---|
| MiB/s | 237 | 213 | **256** |

### mount sync vs async(chunk=8, writers=32, buffer-1m)

| mount | MiB/s | 代价 |
|---|---|---|
| async | 213(重复 256) | — |
| sync | **17.7** | ~12× |

## 结论

1. **随机写随 chunk 缩小单调退化**(4k:9372→4813→4332 IOPS;64k 平稳 1052→890):chunk 8 MiB 的 read-modify-write 粒度是小写最优,与 16 vCPU 节点结论一致(chunk 4 +9% 仅出现在 4K overwrite 单点,本环境未见)。
2. **顺序 buffer 写对 chunk 不敏感**(199-249 MiB/s 同带,顺序写总是命中 chunk 末尾追加,RMW 不触发)。
3. **O_DIRECT 对 chunk 不敏感**(18.5-20.8 MiB/s 同带):每笔同步穿越管线,chunk 粒度不是主导。
4. **writers 16→64 在 buffer-1m 上同带**(213-256):1 GiB 写缓冲是限流器, writers 增加不加速。
5. **mount sync 代价 ~12×**(213→17.7):与 peer 16 vCPU 结果(436→20.9,~21×)同构;仅 buffered 写受影响。
6. repeatability:async buffer-1m 两次独立运行 213/256 MiB/s(±10% 噪声带,共享桌面宿主)。

## 与 16 vCPU 节点结论的对应

- chunk 8 最优:两环境一致(随机写)。
- mount sync 代价:两环境一致(仅 buffered)。
- 线程数:本环境 writers 16/32/64 同带(colima 的限流器是 1 GiB 缓冲);16 vCPU 环境 32→64 提升、128 退化(磁盘饱和)。**FUSE writers 的收益取决于缓冲/内存预算,不是普适单调**。

## 文件

- results.csv — 全部 16 案例(name,bw,iops,expected,landed,rc)
- *.fio / *.fio.out — 每案例 fio job 与原始输出
- runner:`results/k8s-local/mid-config-sequential/k8s-single-case-runner.sh`(LAND_MODE/mount-extra 版)
