# 本地 K8s(colima/kind)分层写性能归因报告

时间:2026-11-18|环境:colima VM(Virtualization.framework,aarch64,8 vCPU / 8 GiB / 168G 盘)上的 kind 集群(kindest/node:v1.32.0),单容器 Ganesha+FUSE Pod

## 一、被测对象与结论先行

被测对象是单容器臂:`weed mount`(SeaweedFS FUSE)+ Ganesha NFSv4 同一容器、同一 mount namespace,宿主(节点)内核 NFS client 经 NodePort 访问。

**结论**:
1. **网络层零损耗**:podIP / ClusterIP / NodePort 三条路径 iperf3 吞吐 33-37 Gbit/s,差异在噪声内。kube-proxy DNAT、未来的 MetalLB(L2 = ARP + 同样的 DNAT)都不构成瓶颈,用 NodePort 对照即可排除 LB 变量。
2. **损耗集中在数据管线,不在网络**:`裸盘 ~300 MiB/s → FUSE+weed ~59-89 → NFS 全栈 22-48`。两个环节:SeaweedFS FUSE 上传管线(÷3-5)和 Ganesha VFS-on-FUSE + NFS 协议(÷2-3)。
3. **三写模式同栈对比,强制步进反而最快**(fsync-per-write 72.5 > fsync16 21.9 ≈ O_DIRECT 20-23 > 无界 buffer 10.9):瓶颈是异步上传管线的排队动力学,不是各层本身。给 NFS 客户端内核设 `vm.dirty_bytes=2GiB` 后 buffer 模式 +104%,复现并证实了裸金属轮 R35 的修复在本环境同样生效。
4. **IO 线程 = 2×vCPU** 是护栏不是常量:weed `concurrentWriters/Readers` 与 Ganesha `RPC_Ioq_ThrdMax` 从 128/64 降到 16(2×8vCPU)后,节点 load 从 36(4 vCPU,9× 超订阅)降到 13(8 vCPU,~1.6×)。已改为 env 可调(`CONCURRENT_WRITERS`/`CONCURRENT_READERS`),核数更多的主机应同步调高。

**定位声明**:本报告是嵌套桌面环境(colima/kind,宿主为共享桌面)里的**归因研究**,绝对值有 ±30-40% 噪声带,不构成性能结论;跨臂对比以裸金属 lab 主机矩阵为准。

## 二、网络阶梯(iperf3,单流,节点内客户端)

| 路径 | 吞吐 |
|---|---|
| node → podIP(裸 CNI/veth) | 36.9 Gbit/s |
| node → ClusterIP(kube-proxy DNAT) | 33.4 Gbit/s |
| node → NodePort loopback(kube-proxy + service) | 33.1 Gbit/s |

## 三、存储阶梯(1MiB 顺序缓冲写)

| 层 | 吞吐 | 相对上一层 |
|---|---|---|
| L0 colima 裸盘(节点 fio,libaio iodepth 16) | 237-392 MiB/s(噪声带,取 ~300) | — |
| L1 pod 内 weed FUSE 挂载直写(无 NFS/Ganesha;dd conv=fsync 4 GiB) | 59-93 MiB/s | ÷3-5 |
| L2 NFS(NodePort)→ Ganesha → FUSE,fio 1M iodepth 16 | 22-48 MiB/s | ÷2-3 |

## 四、三写模式矩阵(8 vCPU,threads=16,10 GiB/案例,fsync1 探针 2 GiB,全部落盘校验通过)

| 模式 | fio 配置 | 带宽 | 落盘 |
|---|---|---|---|
| buffer | direct=0,无 fsync | 10.9 MiB/s | 12.40 GB ✓ |
| fsync16 | direct=0,fdatasync 每 16 块 | 21.9 MiB/s | 11.89 GB ✓ |
| fsync1 | direct=0,fsync 每块(2 GiB 探针) | **72.5 MiB/s** | 2.18 GB ✓ |
| odirect-1m | direct=1,bs=1M | 23.0 MiB/s | 11.89 GB ✓ |
| odirect-8m | direct=8,bs=8M | 20.1 MiB/s | 11.94 GB ✓ |

注:服务端 MaxWrite=1MiB,bs=8M 实际拆为 8×1MiB NFS op;buffer 模式在设 `vm.dirty_bytes` 后复测为 **22.2 MiB/s(+104%)**,即强制同步/限流的收益本质是把管线从"积压-节流"拉回"排空-稳态"。

## 五、pod/container 影响隔离实验

| 变量 | 实验 | 效果 |
|---|---|---|
| Service/转发层 | iperf3 三路径对照 | ≈0 |
| pod CPU limit(cpu=2 → 解除) | buffer-1m 31.9 → 48.8 MiB/s | +53% |
| 节点脏页上限(dirty_bytes 0 → 2GiB) | buffer-1m 10.9 → 22.2 MiB/s | +104% |
| IO 线程 128 → 16(2×vCPU) | 节点 load 36(4vCPU)→ 13(8vCPU) | 消除超订阅噪声 |
| vCPU 4 → 8 | 各层绝对值噪声带 ±30-40%,分层比值稳定 | 超订阅 9× → ~1.6× |

### R35 在本环境的复现

同一内核既跑 NFS client(节点)又背 weed 上传管线(pod)。脏页无上限时:fio 触发 balance_dirty_pages 节流 → 上传管线排队 → 吞吐雪崩(4 vCPU 轮节点 load 36)。`vm.dirty_background_bytes=512MiB / vm.dirty_bytes=2GiB` 后 buffer 模式 +104%。**凡 NFS client 与存储端同机的部署,这两个参数应作为运行条件固定下来**(与裸金属轮 R35 结论一致)。

## 六、过程修复的 CI/环境级缺陷(均已入码)

1. 基础镜像缺 `/etc/mtab`(docker 会在容器启动时补,containerd/kubelet 不会)→ VFS FSAL `setmntent` ENOENT、export 建立失败 → Dockerfile + entrypoint 双保险 `ln -snf /proc/mounts /etc/mtab`。
2. 容器内无 rpcbind → Ganesha 注册失败 FATAL → 构建 `-DRPCBIND=OFF`(NFSv4 固定端口不需要)。
3. `k8s-volume-datsize.sh` awk `%d` 在 mawk(ubuntu runner 默认)下 32 位回绕,>2GiB 统计全错 → `%.0f`。
4. FUSE 根目录 setattr 返回 EAGAIN → 案例/写入改到 `$MNT/fio` 子目录,workflow chmod 同步改。
5. 落盘校验 60s 窗口短于 weed 4GiB 写缓冲的异步上传 → settle 窗口改 `LAND_WAIT`(默认 300s,实测 10GiB 在 +60s 仅 2GiB、+300s 齐平)。
6. 单容器方案(替代两容器 mount-propagation,后者在 Kind 上不生效,见 run 44051984700/44054244166)+ `fetch-weed-binary.sh` 固定 weed 来源。

## 七、colima 环境 ops 备忘(每次 stop/start 后)

```bash
# 1) inotify 上限回默认 128,kube-proxy 会 EMFILE 崩溃:
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=2097152
# 2) 节点容器 nofile 软上限回 1024:
docker exec <node> bash -c 'prlimit --pid $(pgrep -x containerd|head -1) --nofile=524288:524288; \
  prlimit --pid $(pgrep -f kubelet|head -1) --nofile=524288:524288'
# 3) 重启 kube-proxy / local-path-provisioner / coredns pod
# 4) 若 NFS 挂载报 Stale file handle:ganesha pod 重启后必须 umount -l + 重新 mount
```

## 八、下一步

1. push 后 CI 重跑冒烟(预计本报告第六节的坑已在码内修掉)
2. NodePort vs MetalLB-IP 正式对照、host 侧 fio,在 lab 主机(MetalLB + root 权限)做
3. `-chunkSizeLimitMB`(2 → 8-16MiB)对照,针对 L0→L1 的 ÷3-5
4. Ganesha worker/线程、weed buffer 参数在裸金属上的扫描(本地噪声不足以分辨)

## 九、VM 原生对照臂(非 K8s):定位 pod/容器层影响

同一个 VM、同一块盘、同一个内核 NFS client(节点),把同一套 Ganesha V15.9 + weed 4.54(同二进制、同 flags、threads=16)以**裸进程**方式跑在 VM 上(master/volume/filer 127.0.0.1:19350-19354,weed FUSE 挂载,ganesha 0.0.0.0:20490),与 K8s pod 臂对照。

### 调试中发现并修复的两个配置问题

1. 原生脚本漏了 volume server 的 `-master.peers` → 永不向 master 注册("0 node candidates")→ AssignVolume 全挂起 → NFS 写静默丢失(fio rc=0 但文件停在 ~1GiB、filer file_count=0)。
2. fork master 的**状态丢失保护**:重建 raft 后 volume growth 保持冻结("volume growth is frozen after master state loss"),同样让 AssignVolume 挂起。解法:`volume.growth.resume`(已固化进原生臂启动脚本,每次 start 自动执行)。

K8s 臂从不踩这两个坑:master raft 在 PVC 里持久化、volume manifest 自带 master.peers。**用户假设成立:是配置问题,不是代码缺陷。**

### 修复后的对照结果(同 VM、同内核 client、同 fio、1.5GiB O_DIRECT 1M 顺序)

| 臂 | O_DIRECT 1M | buffer 1M |
|---|---|---|
| VM 原生裸进程(无 docker 无 K8s) | **606 MiB/s** | 284 MiB/s |
| K8s pod 臂(NodePort 32049) | 40.8 MiB/s | 43.6-48.8 MiB/s |

原生臂其余模式:fsync16 309 / fsync1(512MiB)817 MiB/s,全部落盘精确。

### 归属解读

同栈裸进程与 pod 化之间存在 **一个数量级** 的差距(15×@odirect)。构成:① pod 化把 filer/volume 从"与 mount 同机的本地进程"变成"跨 ClusterIP 的 pod"(每个 2MiB chunk 上传多一跳 RPC 往返,延迟而非带宽——网络层带宽已证零损耗);② NFS→Ganesha→FUSE→weed→filer→volume 六段链路的每操作延迟在 O_DIRECT 同步写下逐层复利;③ pod 的 cgroup 内存上限客观上起到了限流护栏作用(原生无上限的 weed 在 8GiB VM 上出现过 >2GiB 写入时 mount→filer grpc 断链楔死,D 状态堆积 load 59,恢复用 FUSE abort + 重启 mount/ganesha;详见 results/k8s-local/native-arm-finding/)。

### 原生臂遗留事项

- >2GiB 持续写仍可楔死 mount→filer grpc(3 次,D 堆积),需 weed goroutine dump 定位;
- ganesha/weedmount 任一重启后 NFS client 必须重挂(句柄过期,R10);
- 原生臂启动脚本已含 growth.resume 修复,归档于 results/k8s-local/native-arm-finding/native-arm-setup.sh。

## 十、16 vCPU / 24 GiB 持续写对照(独立复验,2026-11-18)

在 16 vCPU 节点上以 size=12G × numjobs=2(24 GiB 持续写)对 Host 臂与 K8s 臂做了调参前后对照,与第八节 colima 的归因结论**全部同向互验**:

| 配置 | Host | K8s | clat Host/K8s | 用时 |
|---|---|---|---|---|
| 基线 | 80.9 MiB/s | 82.4 MiB/s | 221/219 ms | 304/298 s |
| 调参后 | 255.0 MiB/s | 254.0 MiB/s | 107/111 ms | 96/97 s |
| 提升 | 3.15× | 3.08× | ~2× | ~3.1× |

调参四项(colima 轮全部独立命中):
1. `vm.dirty_bytes=2GiB / vm.dirty_background_bytes=512MiB`(R35 预防,colima 轮实测 +104%);
2. 解除 master/volume/filer 的 CPU limits(仓库先例:解除后 +53%);
3. IO 线程 2×vCPU:16 vCPU → 32(`CONCURRENT_WRITERS/READERS=32`、`RPC_Ioq_ThrdMax=32`,pod env + ConfigMap + Host 臂同步);
4. `CHUNK_SIZE_LIMIT_MB=8`(entrypoint 已 env 化;24 GiB chunk 数 ~12,288→~3,072,落盘开销 27.5→24.6 GiB)。

关键观察:
- 基线瓶颈是持续写后端排队(clat ~220 ms 为证),非 fio 非 placement;
- 调参后 255 MiB/s 已与 8-job 短突发(261)持平——buffered 写从"积压-节流"回到稳态;
- **Host 与 K8s 差距缩至 0.4%**——瓶颈不再是 Ganesha/FUSE 位置,而是共享后端/磁盘;
- 线程 128 反而退化到 244 MiB/s 且 dm-0 util 峰值 99.5%(本地盘打满);**64 为当前最优**,待补重复样本;
- MaxWrite/PrefWrite=1MiB 保持(NFSv4.1 wsize 上限,不应盲目调大)。

产物:/tmp/{baseline24g,tuned24g}-{host,pod}.log。entrypoint 的 `CHUNK_SIZE_LIMIT_MB` env 化已入码(默认 2 不变,CI 行为不变;16 vCPU 部署以 pod env 设 8)。

### 补充:colima(8 vCPU)上的模式-节流耦合发现

在 8 GiB colima 上的对照发现一个跨环境成立的规律:**同步写(fsync=1)反而显著快于无界 buffer**(K8s 臂 303 vs 43.6 MiB/s @fsync1-2g vs buffer-1m;原生臂 817/72.5 vs 284/19.2 同序)。机理:同步写逐笔穿透管线、绕开客户端脏页节流,而 buffered 写受 `vm.dirty_bytes` 封顶(2 GiB)节流——封顶是 R35 预防的必要条件,但也意味着 buffered 模式的上限由"管线排水速度"决定。

### 配置跨机迁移的边界

16 vCPU 机器的最优组合(RPC_Ioq_ThrdMax=128 + FUSE writers=64 + chunk=8MiB)在 8 GiB colima 上**完全无法工作**(连 fio layout 都无法在 600 s 内完成,即便 pod CPU limit 已给满 8 核):4 GiB 写缓冲 + 64×8 MiB 并发在 8 GiB 内存机器上是 R35 类隐患的放大形态。结论:**IO 线程/并发参数必须按机器重标定**(内存、核数、后端盘),不存在跨机通用值;2×vCPU 是防超订阅的保守下限,上限以"后端磁盘 util 接近饱和且 load 不超核数"为界。

### 中档配置严格串行结果(8 vCPU colima,1.5GiB/案例,案例间 vacuum 回收)

| 模式 | K8s 臂(中档配置) | VM 原生臂(参照) | 差距 |
|---|---|---|---|
| buffer-1m | **313 MiB/s** | 284 MiB/s | 已追平(+10% 噪声)|
| fsync16-1m | 72.1 MiB/s | 309 MiB/s | 4.3× |
| odirect-1m | 29-30.1 MiB/s | 606 MiB/s | ~20× |

严格串行协议:单 fio → 完成 → 停止 → 删测试文件 → `volume.vacuum -garbageThreshold=0.01` 回收(40+ GiB 死数据 → 2.4 GiB)→ 下一案例。buffer 差距已消除(1 GiB 写缓冲在 8 GiB VM 上正确限流);sync 模式剩余 4-20× 差距 = 上传排水经 pod 网络的固有损耗(解除后端 CPU limits 无效,非 CPU 瓶颈),优化方向为 sync 刷盘路径的上传并发或存储面 hostNetwork 部署。
