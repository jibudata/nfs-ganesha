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
