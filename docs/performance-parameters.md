# Ganesha + weed FUSE 性能测试完整参数清单（可复现）

> 适用：Kind 单节点 + K8s 内 SeaweedFS + Ganesha/weed FUSE（host 臂或 pod 臂）
> 更新：2026-11-18
> 目标：在另一台测试节点上复现同一套 IO 测试；只有 placement（host vs pod）或被测参数不同。

## 0. 当前最佳配置速览

| 层 | 参数 | 最佳值 |
|---|---|---|
| fio | bs / iodepth / numjobs / size | `1M` / `16` / `2` / `12G`（共 24 GiB） |
| 客户端 | NFS 挂载 | v4.1、TCP、rsize=wsize=1 MiB、hard |
| Ganesha | `RPC_Ioq_ThrdMin` / `RPC_Ioq_ThrdMax` | `8` / `200` |
| weed FUSE | `-concurrentWriters/-concurrentReaders` | `64` / `64` |
| weed FUSE | `-chunkSizeLimitMB` / `-writeBufferSizeMB` | `8` / `4096` |
| weed FUSE | `-fuse.maxBackground` / `-fuse.congestionThreshold` | `128` / `0` |
| weed FUSE | `-cacheCapacityMB` / cache 位置 | `128` / **tmpfs** |
| weed FUSE | `-metadataFlushSeconds` / `-dlm` | `120` / 开启 |
| OS | `vm.dirty_bytes` / `vm.dirty_background_bytes` | `2 GiB` / `512 MiB` |
| K8s 资源 | 后端 CPU limit | 全部移除（仅保留 memory limit） |
| K8s 资源 | Ganesha/FUSE pod | 仅 requests，无 limits |

实测（24 GiB buffered，host 臂）：**80.9 MiB/s → 406–439 MiB/s**（约 5×），pod 臂同配置约 343–394 MiB/s。

> 持久性语义（`end_fsync=1` 到底保证什么、进程崩溃/断电实测、`fsync=true` 的 ~28% 吞吐代价）
> 见 [data-integrity-durability.md](data-integrity-durability.md)。

---

## 1. 环境与拓扑

| 项 | 值 |
|---|---|
| 集群 | Kind 单节点，节点名 `kagent-control-plane`，node IP `172.18.0.2` |
| 宿主机 | Ubuntu，16 vCPU，62 GiB RAM |
| 数据盘 | NVMe `nvme0n1`（YMTC PC411 953.9G），ext4 on LVM（`ubuntu-vg/ubuntu-lv`） |
| 盘调度器 | `none`（NVMe），`read_ahead_kb=128`（默认，未调） |
| 其他盘 | `sda` 2T HDD，未用于本测试 |
| SeaweedFS | 4.54（master/volume/filer 均在 `ganesha-seaweedfs` namespace） |
| Ganesha | 15.9，NFSv4.1 |
| fio | 3.36，libaio |
| 镜像 | `seaweedfs-lab:4.54`、`seaweedfs-lab:ganesha-v15.9`、`seaweedfs-lab:fio`（本地构建 + kind import，无 registry） |

数据路径：

```text
host fio ──NFSv4.1──► host Ganesha :2049 ──► host weed FUSE ──┐
                                                              ├─► filer 172.18.0.2:8888
host fio ──NFSv4.1──► pod  Ganesha :32049 ──► pod weed FUSE ──┘        │
                                                                      └─► volume 172.18.0.2:8080 ─► master 172.18.0.2:9333
```

hostPort 方案（不用 MetalLB/LoadBalancer）：

| 组件 | 注册/访问地址 | gRPC | K8s 端口 |
|---|---|---|---|
| master | `172.18.0.2:9333` | `19333` | hostPort 9333/19333 |
| filer | `172.18.0.2:8888` | `18888` | hostPort 8888/18888 |
| volume | `172.18.0.2:8080` | `18080` | hostPort 8080/18080 |
| NFS（pod 臂） | `172.18.0.2:32049` | — | NodePort 2049→32049 |

---

## 2. OS 参数

### 2.1 已调整

```bash
# 2 GiB dirty 上限 / 512 MiB 后台回写阈值（宿主机全局，NFS client + FUSE + volume 共用）
sudo sysctl -w vm.dirty_ratio=20
sudo sysctl -w vm.dirty_background_ratio=10
# 内核在写 bytes 后会把 ratio 归零
sudo sysctl -w vm.dirty_bytes=2147483648
sudo sysctl -w vm.dirty_background_bytes=536870912
```

持久化写入 `/etc/sysctl.d/99-ganesha-perf.conf`：

```conf
vm.dirty_bytes = 2147483648
vm.dirty_background_bytes = 536870912
```

恢复默认：

```bash
sudo sysctl -w vm.dirty_ratio=20
sudo sysctl -w vm.dirty_background_ratio=10
# 这两条会把 dirty_bytes / dirty_background_bytes 置 0
```

注意：`dirty_bytes` 越大，崩溃时未落盘的数据窗口越大。**不要**在未评估数据风险时调到 4 GiB 以上。

### 2.2 未调整（记录当前值，便于复现）

| 参数 | 当前值 | 说明 |
|---|---|---|
| `vm.swappiness` | 60 | 默认；测试不依赖 swap |
| `vm.dirty_expire_centisecs` | 3000 | 默认 |
| `vm.dirty_writeback_centisecs` | 500 | 默认 |
| `sunrpc.tcp_slot_table_entries` | 2 | NFSv2/3 遗留槽位；v4.1 用 session slots |
| NVMe scheduler | `none` | 默认，保持 |
| read_ahead | 128 KiB | 默认；顺序读测试可再调 |

无 CPU 绑核、无 irqbalance/CPU governor 改动、无 ulimit 改动。

---

## 3. K8s 内 SeaweedFS 后端

namespace：`ganesha-seaweedfs`；所有 manifest 在 `seaweedfs-lab/k8s/ganesha-seaweedfs/`。

### 3.1 master（`10-master.yaml`）

```text
image: seaweedfs-lab:4.54
command: /usr/local/bin/weed master
args:
  -ip=172.18.0.2
  -ip.bind=0.0.0.0
  -port=9333
  -port.grpc=19333
  -mdir=/data/master
  -peers=none
  -vacuumIntervalSeconds=86400
  -telemetry=false
  -volumeSizeLimitMB=4096
ports: 9333/19333（hostPort 同端口）
PVC: 1Gi
resources:
  requests: cpu 100m, memory 128Mi
  limits:   memory 1Gi        # 无 CPU limit
```

### 3.2 volume（`20-volume.yaml`）

```text
image: seaweedfs-lab:4.54
command: /usr/local/bin/weed server
args:
  -master=false
  -filer=false
  -ip=172.18.0.2
  -ip.bind=0.0.0.0
  -volume.port=8080
  -volume.port.grpc=18080
  -master.peers=172.18.0.2:9333
  -master.port=9333
  -master.port.grpc=19333
  -dir=/data/vol
  -volume.max=64
  -volume.readMode=local
  -dataCenter=dc1
ports: 8080/18080（hostPort 同端口）
PVC: 20Gi（local-path）
resources:
  requests: cpu 250m, memory 256Mi
  limits:   memory 4Gi        # 无 CPU limit
```

### 3.3 filer（`30-filer.yaml`）

```text
image: seaweedfs-lab:4.54
command: /usr/local/bin/weed filer
args:
  -ip=172.18.0.2
  -ip.bind=0.0.0.0
  -port=8888
  -port.grpc=18888
  -master=172.18.0.2:9333
  -defaultStoreDir=/data/ldb
ports: 8888/18888（hostPort 同端口）
PVC: 2Gi
resources:
  requests: cpu 250m, memory 256Mi
  limits:   memory 4Gi        # 无 CPU limit
```

> S3 Deployment（`seaweedfs-s3`）在 namespace 中存在但空闲，不是本测试路径。测试期间不要跑 S3 写入。

---

## 4. Ganesha 参数（host 臂与 pod 臂相同）

配置文件：host `seaweedfs-lab/k8s/ganesha-seaweedfs/host-arm/ganesha.conf`；pod 为 `40-ganesha-fuse.yaml` 的 ConfigMap。

```text
NFS_CORE_PARAM {
    NFS_Port = 2049;
    RPC_Ioq_ThrdMin = 8;
    RPC_Ioq_ThrdMax = 200;          # TIRPC 上限，不是固定线程数
    RPC_Max_Connections = 1024;
    MaxRPCSendBufferSize = 1048576;
    MaxRPCRecvBufferSize = 1048576;
    Enable_UDP = false;
    Enable_TCP_keepalive = true;
    Protocols = 4;
    Enable_Metrics = false;
    Enable_Dynamic_Metrics = false;
}

NFSv4 {
    Lease_Lifetime = 10;
    Grace_Period = 10;
    minor_versions = 0,1;
    Delegations = false;
}

NFS_KRB5 { Active_krb5 = false; }
DIRECTORY_SERVICES { DomainName = localdomain; }

EXPORT {
    Export_Id = 1;
    Path = /home/ys1000/seaweedfs/mnt-k8s;   # host 臂；pod 臂为 /mnt/seaweedfs
    Pseudo = /seaweedfs-host;                # host 臂；pod 臂为 /seaweedfs
    Access_Type = RW;
    Squash = Root_Squash;
    Protocols = 4;
    Transports = TCP;
    SecType = sys;
    MaxWrite = 1048576;
    MaxRead = 1048576;
    PrefWrite = 1048576;
    PrefRead = 1048576;
    PrefReaddir = 1048576;
    FSAL { Name = VFS; }
}

EXPORT_DEFAULTS {
    Access_Type = RW;
    Squash = Root_Squash;
    Protocols = 4;
    Transports = TCP;
    SecType = sys;
}

LOG {
    Facility { name = FILE; destination = /tmp/ganesha-host-arm.log; enable = active; }
    Default_Log_Level = EVENT;
}
```

启动：

- **host 臂**（必须在 FUSE mount 之后启动 Ganesha，R10）：
  ```bash
  sudo /usr/bin/ganesha.nfsd -x -F -f <host-arm.conf> -N NIV_EVENT \
    -L /tmp/ganesha-host-arm.log -p /tmp/ganesha-host-arm.pid
  ```
- **pod 臂**：由 `ganesha-entrypoint` 在 FUSE mount 就绪后启动
  `/usr/bin/ganesha.nfsd -F -f /etc/ganesha/ganesha.conf -N NIV_EVENT -L /dev/stderr`。
- `RPC_Ioq_ThrdMax` 可以通过 `kill -HUP <ganesha-pid>` 热加载（日志出现 `Update of svc parameters`），也可重启 Ganesha（不必重启 FUSE mount）。

实测：24 GiB / 2 job 下线程池峰值约 **91–95** 个 I/O 线程（上限 200 不常驻，只是 ceiling）。

---

## 5. weed FUSE 参数（host 臂与 pod 臂相同）

```bash
weed mount \
  -filer=172.18.0.2:8888 \
  -dir=<挂载点> \
  -volumeName=seaweedfs-ganesha-pod \
  -allowOthers=true \
  -defaultPermissions=true \
  -umask=022 \
  -cacheDir=<tmpfs 目录> \
  -cacheCapacityMB=128 \
  -cacheMetaTtlSec=60 \
  -chunkSizeLimitMB=8 \
  -writeBufferSizeMB=4096 \
  -concurrentWriters=64 \
  -concurrentReaders=64 \
  -metadataFlushSeconds=120 \
  -fuse.maxBackground=128 \
  -fuse.congestionThreshold=0 \
  -df.logical \
  -dlm
```

| 臂 | `-dir` | `-cacheDir` |
|---|---|---|
| host | `/home/ys1000/seaweedfs/mnt-k8s` | `/dev/shm/seaweedfs-host-fuse-cache`（tmpfs） |
| pod | `/mnt/seaweedfs` | `/cache`（emptyDir `medium: Memory`，`sizeLimit: 512Mi`） |

导出子目录：两个臂都在 FUSE mount 后创建 `<dir>/data` 并 `chmod 0777`（Root_Squash + FUSE 根目录不可写；FUSE 根 setattr 会被拒）。

**tmpfs cache 的作用（实测）**：cache 在磁盘上时，每个 chunk 先写 cache 再写 volume `.dat`，磁盘写放大约 **1.8×**；移到 tmpfs 后客户端吞吐从 ~305 MiB/s 提升到 ~350–430 MiB/s。

### 5.1 mount 关键参数：默认值 vs 本次取值

| 参数 | weed 默认 | 本次值 | 说明 |
|---|---:|---:|---|
| `chunkSizeLimitMB` | 2 | **8** | 8 最优；4/2 实测更慢 |
| `concurrentWriters` | 128 | **64** | 与 Ganesha RPC 并发配合；128 反而下降 |
| `concurrentReaders` | 128 | **64** | 与 writers 对称 |
| `readerCacheSizeMB` | 256 | 未设置（256） | 读缓存预算，写测试不敏感 |
| `writeBufferSizeMB` | 0（不限制） | **4096** | 4 GiB 内存缓冲；不继续加大（崩溃窗口） |
| `fuse.maxBackground` | 128 | **128** | 256 实测更慢 |
| `fuse.congestionThreshold` | 0 | **0** | 关闭拥塞阈值 |
| `writebackCache` | false | **false** | 开启后 close 异步 flush，源码标注 crash 丢数据风险 |
| `asyncDio` | false | **false** | 未使用 |
| `dlm` | false | **开启** | 跨 mount 一致性；关闭实测无收益 |

> `-writebackCache` 默认 false 是有利默认值；显式 `fsync` 即使开启它也是同步 flush，但 close()
> 的异步 flush 会扩大崩溃丢失窗口，不建议在测试/生产开启。

---

## 6. Pod 臂专属参数（`40-ganesha-fuse.yaml`）

```text
Deployment seaweedfs-ganesha-fuse（replicas 1, strategy Recreate）
container ganesha-fuse:
  image: seaweedfs-lab:ganesha-v15.9
  imagePullPolicy: Never
  command: /usr/local/bin/ganesha-entrypoint
  env:
    FILER=172.18.0.2:8888
    EXPORT_SUBDIR=data
    CONCURRENT_WRITERS=64
    CONCURRENT_READERS=64
    CHUNK_SIZE_LIMIT_MB=8
  securityContext: privileged: true        # 需要 /dev/fuse + CAP_SYS_ADMIN
  ports: 2049/TCP
  readinessProbe: FUSE mount 存在 且 TCP 2049 可连接
  livenessProbe:  tcpSocket 2049
  resources:
    requests: cpu 500m, memory 512Mi
    limits:   无（为与 host 臂公平对比）
volumes:
  /dev/fuse          hostPath /dev/fuse (CharDevice)
  /mnt/seaweedfs     emptyDir
  /cache             emptyDir medium: Memory, sizeLimit: 512Mi
  /var/log           emptyDir
  /etc/ganesha       ConfigMap ganesha-fuse-config
Service seaweedfs-ganesha-fuse: NodePort 2049 → 32049
```

> 修改 ConfigMap 后必须 `kubectl rollout restart deploy/seaweedfs-ganesha-fuse`，否则 Ganesha 进程仍用旧配置。

---

## 7. Host 臂专属参数

脚本：`seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh up|status|down`

关键点：

- `HOST_MNT=/home/ys1000/seaweedfs/mnt-k8s`
- `HOST_CACHE=/dev/shm/seaweedfs-host-fuse-cache`
- filer 用 `172.18.0.2:8888` hostPort；volume 由 filer 返回 `172.18.0.2:8080`
- **先 FUSE mount，成功后再启动 host Ganesha**
- 创建 `/home/ys1000/seaweedfs/mnt-k8s/data`（0777）
- NFS 客户端挂到 `/mnt/ganesha-host-arm`

---

## 8. NFS 客户端挂载

### Host 臂

```bash
sudo mkdir -p /mnt/ganesha-host-arm
sudo mount -t nfs \
  -o vers=4.1,proto=tcp,port=2049,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  127.0.0.1:/seaweedfs-host /mnt/ganesha-host-arm
```

### Pod 臂

```bash
sudo mkdir -p /mnt/ganesha-seaweedfs
sudo mount -t nfs \
  -o vers=4.1,proto=tcp,port=32049,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  172.18.0.2:/seaweedfs /mnt/ganesha-seaweedfs
```

当前**未**使用 `nconnect` / `max_session_slots`（作为后续候选，见第 12 节）。测试节点需要 `nfs-common`。

---

## 9. fio 参数与命令

24 GiB 用例（覆盖 4 GiB 卷）：

```ini
[global]
ioengine=libaio
rw=write
bs=1M
direct=0
iodepth=16
size=12G
fallocate=none
end_fsync=1
scramble_buffers=1
directory=/mnt/ganesha-host-arm/data      ; pod 臂改为 /mnt/ganesha-seaweedfs/data
filename_format=perf-24g.$jobnum
group_reporting=1

[perf-24g]
numjobs=2
```

```bash
fio perf-24g.fio --output=perf-24g.log --output-format=normal
```

- `size=12G × numjobs=2` = **24 GiB 总量**（不是 12 GiB）。
- `end_fsync=1` 会等待后端 drain；进度 100% 后停顿几秒是正常现象。
- 每个用例建议跑 3 次，取均值/中位数/极值；同一配置的 run-to-run 波动约 ±10%。

---

## 10. 在另一台测试节点复现

1. 准备单节点 Kind（或 k3s）集群；节点 IP 从 `kubectl get nodes -o wide` 获取，记为 `NODE_IP`。
2. 确认 hostPort 未被占用：`9333 19333 8888 18888 8080 18080 32049`。
3. 构建并导入镜像：
   ```bash
   # 镜像构建方式见 seaweedfs-lab/docker/
   kind load docker-image seaweedfs-lab:4.54
   kind load docker-image seaweedfs-lab:ganesha-v15.9
   ```
4. 把 manifest 与脚本中的 `172.18.0.2` 全部替换为 `NODE_IP`：
   ```bash
   grep -rl 172.18.0.2 seaweedfs-lab/k8s/ganesha-seaweedfs seaweedfs-lab/scripts | \
     xargs sed -i "s/172\.18\.0\.2/$NODE_IP/g"
   ```
5. 准备 local-path（或等价）存储，至少 20 GiB 给 volume PVC；宿主需要 `/dev/fuse`，pod 需允许 privileged。
6. 应用顺序：
   ```bash
   bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh up     # namespace + master/volume/filer/pod 臂
   bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh up  # 可选：host 臂
   ```
7. 设置 OS dirty 参数（第 2 节），挂载 NFS（第 8 节），跑 fio（第 9 节）。
8. 两臂必须**串行**测试，不能同时对同一个 filer/volume 压测。

宿主机路径 `/home/ys1000/...` 需要按测试节点用户名/目录调整（脚本里是 `HOST_MNT/HOST_CACHE/NFS_MNT`）。

---

## 11. 清理与空间回收

每次测试后：

```bash
# 1) 通过 NFS 删除数据
rm -rf /mnt/ganesha-host-arm/data/perf-*
sync

# 2) 让 FUSE 把删除元数据 flush 到 filer（metadataFlushSeconds=120）
#    最简单：先 down 再 up host 臂；pod 臂用 rollout restart
sudo umount /mnt/ganesha-host-arm
# 重新 mount 后继续

# 3) 删除 filer change log（/topics 不在 NFS 导出中，但占 volume chunk）
curl -X DELETE "http://$NODE_IP:8888/topics/.system/log/$(date +%F)?recursive=true"

# 4) vacuum
printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333

# 5) 轮询 .dat 总量直到稳定
kubectl -n ganesha-seaweedfs exec sts/seaweedfs-volume -- \
  sh -c 'du -sb /data/vol | cut -f1'
```

> **顺序很重要**：FUSE 的删除是批量的（120 s 或 unmount 时 flush）。若 `rm` 后立即 vacuum，删除还没到 filer，空间不会被回收——本环境实测出现过“vacuum 后仍剩 24 GiB”，remount 后再 vacuum 才归零。

---

## 12. 实测结果与当前瓶颈

### 12.1 24 GiB buffered 写（host 臂，单次样本）

| 配置 | 吞吐 (MiB/s) | 备注 |
|---|---:|---|
| 初始基线：RPC 16 / FUSE 16 / chunk 2 / dirty 0 / 后端 CPU limit / 磁盘 cache | 80.9 | 起点 |
| RPC 32 / FUSE 64 / chunk 8 / tmpfs cache | 321 | FUSE=32 限制 |
| RPC 64 / FUSE 64 / chunk 8 | 342, 357, 405, 406 | |
| RPC 128 / FUSE 64 / chunk 8 | 417, 426, 439 | |
| RPC 200 / FUSE 64 / chunk 8 | 394 | 线程池峰值 ~91–95 |
| RPC 128 / FUSE 128 | 355 | FUSE 过大反而下降 |
| chunk 4 / chunk 2 | 367 / 247 | chunk 8 最优 |
| `fuse.maxBackground=256` | 349 | 128 更优 |
| `-cacheCapacityMB=512`（tmpfs） | 369 | 128 足够 |
| Ganesha RPC buffer 4 MiB | 383 | 无收益，保持 1 MiB |
| NFS client `nconnect=4` | 375 | 无收益 |
| `-dlm` 关闭 | 359 | 无收益，且有跨 mount 一致性代价 |
| 磁盘 cache（非 tmpfs） | 291, 320 | tmpfs 明显更好 |
| filer rule `fsync=true` | 253（12 GiB） | durable-on-ack；比无规则 351 慢 ~28% |

pod 臂（RPC 64 / FUSE 64 / chunk 8 / tmpfs）：360、364、394 MiB/s；pod RPC=200：343 MiB/s（NodePort/kube-proxy 路径略低于 host 臂）。

### 12.2 瓶颈判断

- NVMe 裸盘（volume PVC 路径）：`dd` O_DIRECT **2.0 GB/s**、buffered **2.8 GB/s** → 盘不是瓶颈。
- 运行中：weed mount ≈ **1.08 核**，Ganesha ≈ **0.30 核**（16 vCPU，均非饱和）。
- NVMe 运行中：util 52–67%，队列深度 90–133，`w_await` ~25 ms → **时延/软件路径限制**，不是带宽限制。
- 结论：当前提升主要来自 **Ganesha RPC 并发** 与 **FUSE 并发/缓存位置**；后端磁盘仍有大量余量。
- 已做单变量/解耦对照（FUSE writers 固定 64 只变 RPC；RPC 固定只变 FUSE writers）：
  - RPC 16 → 106、32 → 225、64 → 406、128 → 426、200 → 394（同 mount 背靠背，64 与 128 在噪声内，200 提供 ceiling 余量）；
  - FUSE writers 32 → 321、64 → 417/439、128 → 355；
  - chunk 4/2、maxBackground 256、4 MiB RPC buffer、cache 512、nconnect、关 DLM 均无收益。
- 当前 run-to-run 波动约 ±10%，对比小差异时至少跑 3 次。

### 12.3 持久性档位（MySQL 式 performance / auto / strict）

| 档位 | 配置 | 实测吞吐 | 断电丢失窗口 |
|---|---|---|---|
| **performance** | 无 fsync rule，默认 writeback（30 s） | 351（12G/1job）、343–439（24G/2jobs，pod/host） | 最多 ~30 s + 设备 cache |
| **auto（推荐）** | 无 fsync rule + `dirty_expire_centisecs=100`、`dirty_writeback_centisecs=100` | **396**（12G/1job，无下降） | **~1–2 s** |
| **group-commit** | fsync rule + volume fsync 批量 | 264（12G/1job）、259（24G/2jobs） | 0（ack 等待 fsync） |
| **strict** | fsync rule + 默认批量（1 MiB/128/500µs） | 253（12G/1job） | 0 |

说明：

- **fsync 规则**：`fs.configure -locationPrefix=/data/ -fsync -apply`。它让 chunk 上传带
  `?fsync=true`，并让 filer 的 CreateEntry 使用 LevelDB `Sync:true`。
- **批量参数**只在开启 fsync 规则时有意义：默认 `MinBytes=1 MiB / MinRequests=128 / Wait=500µs`；
  8 MiB chunk 一个就超过 1 MiB，因此默认等于每 chunk 一次 fsync。调到 64 MiB/5ms 只从
  253 提到 264（12G/1job）/259（24G/2jobs），**没有显著挽回**；fsync 语义本身约 -25~30%。
- 在 `weed server` 下 volume 批量 flag 带前缀：`-volume.fsyncMinBatchBytes`、
  `-volume.fsyncMinBatchRequests`、`-volume.fsyncBatchWait`（`weed volume` 下无前缀）。
- **3 节点 / 2 副本**：每个副本都要 fsync，ack 等所有副本；批量窗口可适当放大
  （如 64–256 MiB、Wait 5–20 ms），但网络复制 + 每副本 fsync 是主要成本，应在目标拓扑上实测。
  建议按路径分级：关键元数据/小文件前缀用 fsync，批量数据用 auto 档。
- **auto 档原理**：ack 不等待 fsync（类似 MySQL `innodb_flush_log_at_trx_commit=2`），由 OS
  回写线程每秒把脏页写盘；丢失窗口约 1–2 s。注意设备自身易失写缓存仍未覆盖，企业级 NVMe
  断电保护/PLP 或 UPS 才谈得上真正的掉电安全。
- **group-commit 原理**：ack 等待批次 fsync（类似 MySQL group commit），保证已确认写不丢；
  代价是 ack 延迟和 ~25–30% 吞吐。

### 12.4 fio 典型矩阵（pod 臂，auto 档，3 次重复）

12 GiB 数据集（>2 个 4 GiB 卷）；顺序大 IO 用 size-based；4K/随机用
`time_based=1, runtime=60`（文件仍为 12 GiB）；读用 `direct=1` 且先 `drop_caches`。

本节是 **2026-11-18 在节点 192.168.3.146 上的同节点 3 次重复**；跨节点复现步骤见第 10 节。
初测（1 次样本）的大 IO 数据与此处 r1 吻合（seq-write 408/209/272 vs 417/207/300，
seq-read 259/321 vs 259/322），差异集中在小 IO/随机写（见下）。

| 用例 | fio direct | 结束 fsync | 数据/读状态 | r1 | r2 | r3 | 均值 | IOPS（r1/r2/r3） |
|---|---|---:|---|---:|---:|---:|---:|---|
| seq-write-1m-buf | 0（buffered） | yes | 新文件 r1 / 覆盖 r2–3 | 417 | 333 | 302 | 351 | 416 / 333 / 301 |
| seq-write-4m-dir | 1（O_DIRECT） | yes | 新文件 r1 / 覆盖 r2–3 | 207 | 151 | 147 | 168 | 51 / 37 / 36 |
| seq-write-8m-dir | 1（O_DIRECT） | yes | 新文件 r1 / 覆盖 r2–3 | 300 | 241 | 227 | 256 | 37 / 30 / 28 |
| seq-read-1m-dir | 1（O_DIRECT） | — | 单遍冷读 | 259 | 274 | 261 | 265 | 258 / 273 / 261 |
| seq-read-4m-dir | 1（O_DIRECT） | — | 单遍冷读 | 322 | 303 | 326 | 317 | 80 / 75 / 81 |
| seq-read-8m-dir | 1（O_DIRECT） | — | 单遍冷读 | 294 | 300 | 276 | 290 | 36 / 37 / 34 |
| seq-write-4k-dir | 1（O_DIRECT） | yes | 覆盖 | 186 | 178 | 168 | 177 | 46 / 44 / 42 |
| seq-read-4k-dir | 1（O_DIRECT） | — | 60 s 重复读 | 304 | 302 | 303 | 303 | 77.8k / 77.2k / 77.7k |
| rand-write-4k-dir | 1（O_DIRECT） | yes | 覆盖 | 15.8 | 23.1 | 23.4 | 20.8 | 3 / 5 / 5 |
| rand-read-4k-dir | 1（O_DIRECT） | — | 60 s 重复读 | 226 | 243 | 236 | 235 | 57.8k / 62.2k / 60.5k |
| rand-write-64k-dir | 1（O_DIRECT） | yes | 覆盖 | 6.6 | 4.9 | 4.0 | 5.2 | 105 / 78 / 64 |
| rand-read-64k-dir | 1（O_DIRECT） | — | 60 s 重复读 | 2847 | 2822 | 2801 | 2823 | 45.6k / 45.1k / 44.8k |
| rand-write-1m-dir | 1（O_DIRECT） | yes | 覆盖 | 28.5 | 26.5 | 26.0 | 27.0 | 28 / 26 / 25 |
| rand-read-1m-dir | 1（O_DIRECT） | — | 60 s 重复读 | 5424 | 5384 | 5422 | 5410 | 5.4k / 5.4k / 5.4k |

> 单位：除 seq-write-4k 与 rand-write-4k 为 KiB/s 外，其余为 MiB/s。
> 命名后缀：`-buf` = buffered（`direct=0`）；`-dir` = direct（`direct=1`，O_DIRECT）。

**IO 模式与 sync 语义（三层要分开看）**：

- **客户端 fio**：只有 `seq-write-1m-buf` 是 buffered（`direct=0`，写走 NFS 客户端
  page cache）；其余全部 `direct=1`（O_DIRECT，绕过客户端 page cache）。所有用例都用
  libaio 异步提交（qd=4–32），**没有** per-IO `fsync=1` 的同步写用例。
- **任务结束**：所有**写**用例都带 `end_fsync=1`（job 结束时把数据/元数据提交到后端）；
  读用例没有。它不等于同步写——写过程中的每个 IO 仍是异步的，只是结尾多一次 drain。
- **后端持久性**：整张表跑在 **auto 档**（无 fsync 存储规则，OS 1 s 回写）。
  `end_fsync=1` 只保证数据到达 volume 页缓存 + filer 提交，**不保证掉电持久**；
  需要 durable-on-ack 请看 §12.3 的 group-commit / strict 档。
- **O_DIRECT 的作用域**：只绕过客户端 page cache。服务端对所有用例仍统一经过
  weed mount 的 4 GiB write buffer、128 MB tmpfs read cache 和 OS 回写（2 GiB / 1 s），
  所以 `direct=1` 并不能绕过 8 MiB chunk 的 RMW。

**怎么读这张表**：

- `seq-write-1m/4m/8m` 的 r1 是**新文件**，r2/r3 是**覆盖同一文件**；写吞吐逐次下降
  （417→333→302、207→151→147、300→241→227）主要是覆盖写触发 8 MiB chunk 的 RMW，
  不能当成纯 run-to-run 噪声。其余 4K/随机写用例本来就是覆盖 12 GiB 数据集。
- `seq-read-*` 是 size-based 单遍冷读，可作为后端冷读参考（265–317 MiB/s）。
- `rand-read-64k/1m` 的 `time_based=60s` 会在 60 s 内反复读同一个 12 GiB 文件；
  `drop_caches` 只保证第一遍是冷的，后续遍数可能命中宿主 page cache。因此
  **2.8/5.4 GiB/s 是冷+热混合上界，不是纯后端带宽**；纯冷读请看 `seq-read-*`。

**关键发现**：

- 小 IO/随机**写**仍受 8 MiB chunk 的 RMW 限制：rand-write-4k **3–5 IOPS**（20.8 KiB/s），
  rand-write-64k 64–105 IOPS（4.0–6.6 MiB/s），rand-write-1m 25–28 IOPS（26–28.5 MiB/s）；
  同尺寸随机读分别为 57.8k / 45.1k / 5.4k IOPS。
- 与初测 1 次样本相比，rand-read-4k（75.2→235 MiB/s）和 rand-write-64k
  （383 KiB/s→5.2 MiB/s）明显更高。初测时 64 个 4 GiB 卷已全部分配、卷内约 220 GiB 是
  未 vacuum 的已删除 chunk，写路径被空间回收/卷分配拖慢。**小写结论必须在干净卷池上取。**
- 8M 读的瞬时 ENOENT 已被脚本的 dd 预热 + 重试覆盖，本次 3 次重复全部成功。
- 大 IO 写：新文件 300–417 MiB/s；覆盖写 147–333 MiB/s。

**本次实测的两个坑**：

- fio 在本栈上会认为 12 GiB 数据集“不够长”，**每个读用例开始前重新 layout 整个 12 GiB 文件**
  （layout 不在计时窗口内，但每次 churn 12 GiB chunk）。多次重复把 64 个 4 GiB 卷写满后，
  fio 报 `ENOSPC`。脚本已给读用例加 `--readonly`（fio 3.36 无 job-file 形式），不再 layout。
- 自动 vacuum 部署时关闭。本次手动 `volume.vacuum` 后 `.dat` 从 244 GiB 回收到 24.2 GiB。
  清理顺序：删测试数据 → `sync` → rollout restart FUSE pod（flush 120 s 批量删除）→ vacuum。
  低于 compaction 阈值的残余已删除 chunk（本次 0.86 GiB）不会立即回收，属正常。

小 IO/随机写与 `chunkSizeLimitMB=2/4` 的对比、以及新文件追加 4K 的结果见 §12.6：
chunk 8 仍最优，追加写比覆盖写快 1.8–3×。

运行：

```bash
# pod 臂，auto 档；CASES 可过滤；3 次重复
CASES=all bash seaweedfs-lab/scripts/bench-ganesha-fio-matrix.sh pod 3
```

### 12.5 NFS 客户端挂载 sync vs async（写路径，10 GiB）

§12.4 的矩阵使用默认 `async` 挂载。这里只改 **NFS 客户端挂载选项**（`sync` vs 默认
`async`），后端（auto 档）、fio 参数和 pod 配置都不变。协议：每个模式开始前重建 10 GiB
数据集；用例结束后删数据、等 130 s（FUSE 删除批量 flush）、手动 `volume.vacuum`，再跑
下一个模式。7 个写用例 × 3 次重复，全部 rc=0。脚本：
`seaweedfs-lab/scripts/bench-mount-sync.sh`。

| 用例 | async | sync | sync/async |
|---|---:|---:|---:|
| seq-write-1m-buf | 436 MiB/s | **20.9 MiB/s** | **0.05×** |
| seq-write-4m-dir | 215 MiB/s | 182 MiB/s | 0.85× |
| seq-write-8m-dir | 285 MiB/s | 260 MiB/s | 0.91× |
| rand-write-1m-dir | 55.3 MiB/s | 43.4 MiB/s | 0.78× |
| seq-write-4k-dir | 217 KiB/s | 170 KiB/s | 0.78× |
| rand-write-4k-dir | 14.9 KiB/s | 14.0 KiB/s | 0.94× |
| rand-write-64k-dir | 457 KiB/s | 459 KiB/s | 1.00× |

逐次（r1/r2/r3）：
- `seq-write-1m-buf`：async 502/403/403，sync 24.6/16.6/21.5 MiB/s。
- `seq-write-4m-dir`：async 248/204/193，sync 219/167/161 MiB/s。
- `seq-write-8m-dir`：async 311/276/269，sync 287/244/249 MiB/s。

**怎么读**：

- **只对 buffered 写有数量级影响**：`sync` 让每次 buffered write 等服务端提交，
  1M buffered 从 436 降到 20.9 MiB/s（20×）。这是全部用例里唯一走客户端 page cache 的。
- **O_DIRECT 大顺序写影响有限**：4M/8M 只慢 9–15%，1M 随机慢 22%。O_DIRECT 已经绕过
  客户端 page cache，主要成本本来就在服务端 chunk 上传/RMW，mount sync 只额外加提交等待。
- **4K/64K 随机写几乎不变**：它们已经被 8 MiB chunk 的 RMW 限制在 2–7 IOPS，
  提交开销相对可忽略。`sync` 不能解决小写问题。
- **注意本节的绝对数不能与 §12.4 直接比**：10 GiB 块在跑到小写用例前已积累约 160 GiB
  已删除 chunk，小写吞吐被卷池状态压低（64K 只有 457 KiB/s，而 §12.4 干净卷池是
  5.2 MiB/s）。本节只用于 **mount 选项的 A/B 差值**；绝对值以 §12.4 为准。
- 这里的 `sync` 是 **NFS mount 选项**，不是 fio `fsync=1`，也不是 SeaweedFS 的
  fsync 存储规则；后端仍是 auto 档。

### 12.6 chunkSizeLimitMB 8/4/2 对小 IO/随机写的影响（10 GiB）

只改 Ganesha/FUSE 部署的 `CHUNK_SIZE_LIMIT_MB`（pod 重启生效），后端和 fio 参数不变。
每个配置重建 10 GiB 数据集；用例后删数据、等 130 s、`volume.vacuum`，再切下一个配置。
4 个用例 × 3 次重复，全部 rc=0；脚本 `seaweedfs-lab/scripts/bench-chunk-size.sh`。
所有用例 60 s time_based、O_DIRECT、`end_fsync=1`、auto 档；append 用例用
`file_append=1` 追加到 1 GiB 文件末尾（追加区域与基文件大小无关）。

| 用例 | chunk 8 MiB | chunk 4 MiB | chunk 2 MiB |
|---|---:|---:|---:|
| seq-write-4k-overwrite | 254 KiB/s (63) | 276 KiB/s (69) | 173 KiB/s (43) |
| seq-write-4k-append | 458 KiB/s (114) | 534 KiB/s (133) | 528 KiB/s (132) |
| rand-write-4k | 28.0 KiB/s (6.7) | 15.0 KiB/s (3.3) | 10.7 KiB/s (2.0) |
| rand-write-64k | 369 KiB/s (5.3) | 408 KiB/s (6.0) | 340 KiB/s (4.7) |

> 括号内是 3 次平均 IOPS。逐次 IOPS：
> overwrite 8M 54/67/68、4M 61/74/72、2M 40/44/44；append 8M 145/104/93、4M 177/124/99、2M 181/121/93；
> rand-4k 8M 7/8/5、4M 5/2/3、2M 4/1/1；rand-64k 8M 8/3/5、4M 6/6/6、2M 5/4/5。

**结论**：

- **chunk 4 对顺序 4K 覆盖写略好（+9%），chunk 2 明显更差（-32%）；随机 4K 随 chunk 变小
  反而变差（8M 最好），随机 64K 基本持平。** 没有把 chunk 降到 2/4 来救小写的理由，
  保持 8 MiB。
- **append 比覆盖写快 1.8–3×**（chunk 8：458 vs 254 KiB/s；chunk 4：534 vs 276；
  chunk 2：528 vs 173）。这直接验证了 8 MiB chunk 的 RMW 是覆盖写的主要成本。
- 但即使 append，4K 也只有约 100–180 IOPS（0.4–0.7 MiB/s），说明上限在单 IO 的
  NFS→Ganesha→FUSE→volume HTTP 路径，而不在 chunk 大小。
- 随机写的绝对值受卷池状态影响大（每个配置在随机用例前已积累数据集和删除 chunk），
  3 次样本的 ±噪声不可忽略；顺序写/追加写的结论比随机写稳。
- 小写优化方向不是 chunk size：避免随机覆盖（append/顺序写）或换写路径（S3 直连等）
  才有数量级空间。

---

## 13. 风险与注意事项

| 项 | 风险 | 建议 |
|---|---|---|
| tmpfs FUSE cache | 节点崩溃时 cache 内容丢失（属既有崩溃窗口的一部分） | host 用 `/dev/shm`，pod 限制 `sizeLimit: 512Mi` |
| `writeBufferSizeMB=4096` | 最多 4 GiB 未落盘数据；崩溃丢失 | 不要为追求吞吐继续加大 |
| `dirty_bytes=2 GiB` | 崩溃时未回写数据窗口 | 不建议 >2 GiB；恢复用 ratio 方式 |
| `metadataFlushSeconds=120` | 元数据 120 s 才 flush | 测试/崩溃恢复语义需知晓 |
| Ganesha/FUSE pod 无 limits | 节点内存压力 / OOM | 稳定后可加 memory limit（勿加 CPU limit） |
| hostPort | SeaweedFS API 暴露在 node IP，无认证 | 仅限隔离测试网络 |
| 单 master/volume | 无 HA，pod 重启期间服务中断 | 测试环境可接受 |
| `/topics` 删除 | 有 S3/事件订阅者时会丢事件 | 仅在本测试栈、无订阅者时删除 |
| 单次样本噪声 | ±10% | 结论用 3 次重复；小差异不要过度解读 |
| 默认无 `fsync` 存储规则 | `end_fsync` 只到 volume 页缓存 + filer 提交，不保证断电持久化 | 需要 durable-on-ack 时对该前缀加 `fsync=true`（吞吐 -28%）；详见 [data-integrity-durability.md](data-integrity-durability.md) |

---

## 14. 后续候选（尚未定论）

- 增加客户端并发（更多 fio jobs / 更大 iodepth；当前 fio 固定 32 outstanding，是吞吐的上限因素之一）。
- OS `vm.swappiness`、`dirty_expire_centisecs` / `dirty_writeback_centisecs`（预计收益有限）。
- SeaweedFS volume `-disk=ssd` / filer change log 关闭（后者有事件语义风险）。
- `writeBufferSizeMB` 8192（会扩大崩溃丢失窗口，不推荐）。

已测试且**无收益**（不要重复）：`MaxRPCSend/RecvBufferSize=4MiB`、`nconnect=4`、`cacheCapacityMB=512`、
`maxBackground=256`、chunk 4/2、关闭 `-dlm`、`max_session_slots=128`（该 mount.nfs 不支持）。
