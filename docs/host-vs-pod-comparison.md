# Ganesha + weed FUSE：宿主机 vs Pod 对比方案

> 共享同一套 K8s 内的 SeaweedFS 后端
> 更新日期：2026-11-18

## 目标

对比 Ganesha + weed FUSE 的两种部署位置：

- **Host 臂**：Ganesha + weed FUSE 在宿主机；SeaweedFS 在 K8s
- **Pod 臂**：Ganesha + weed FUSE 在 K8s Pod；SeaweedFS 在 K8s

两个臂使用**同一个** master/volume/filer、同一个 PVC/磁盘、同一套 4 GiB 卷配置。唯一变量是 Ganesha+FUSE 的位置。

## 架构

```text
host fio ──NFS──► host Ganesha :2049 ──► host weed FUSE ──┐
                                                          ├─► 172.18.0.2:8888 filer
host fio ──NFS──► pod  Ganesha :32049 ──► pod weed FUSE ──┘        │
                                                                   └─► volume 172.18.0.2:8080 ─► master
```

## 为什么用 hostPort，而不是 LoadBalancer / NodePort

- FUSE 挂载从 filer 得到 volume 的**注册地址**；宿主机必须能路由它。
- Pod IP 只在集群内可路由，宿主机不行。
- MetalLB 可以，但会引入 LB 的 ARP/数据路径，增加一个非 placement 变量。
- NodePort 会改变 node 上的端口，而：
  - filer 客户端按 **gRPC = HTTP + 10000** 推导；
  - volume 注册的端口是它的真实监听端口（8080）。

  这两条约定在 NodePort 端口偏移下都会被破坏。
- **hostPort** 保留原端口，宿主机和 Pod 都通过 node IP 访问；不涉及 LB。

三个组件都注册 node IP（当前 `172.18.0.2`）：

| 组件 | 注册 / 访问地址 | gRPC |
|---|---|---|
| master | `172.18.0.2:9333` | `19333` |
| filer | `172.18.0.2:8888` | `18888` |
| volume | `172.18.0.2:8080` | `18080` |

这些 hostPort 由 `ganesha-seaweedfs` 的 Pod 绑定到 node；K8s Service 仍为 ClusterIP，仅用于状态/健康检查。NFS Service 仍是 NodePort（`2049:32049`）。

## 启动

共享后端 + Pod 臂：

```bash
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh up
```

Host 臂：

```bash
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh up
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh status
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh down
```

Host 臂脚本会：

- 从 `172.18.0.2:8888` 挂载 host weed FUSE 到 `/home/ys1000/seaweedfs/mnt-k8s`；
- 使用与 Pod 臂相同的 FUSE 参数（64/64 writers/readers、128 MB **tmpfs** cache、8 MB chunk、4 GB write buffer、`-dlm`）；
- **在 FUSE mount 就绪后**启动 host Ganesha（`/tmp/ganesha-host-arm.pid`，配置在 `k8s/ganesha-seaweedfs/host-arm/ganesha.conf`）；
- 挂载 host NFS 客户端到 `/mnt/ganesha-host-arm`。

Pod 臂的 host NFS 客户端：

```bash
sudo mkdir -p /mnt/ganesha-seaweedfs
sudo mount -t nfs \
  -o vers=4.1,proto=tcp,port=32049,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  172.18.0.2:/seaweedfs /mnt/ganesha-seaweedfs
```

## 测试目录

| 臂 | 宿主机路径 | NFS server |
|---|---|---|
| Host | `/mnt/ganesha-host-arm/data` | host Ganesha `127.0.0.1:2049`，pseudo `/seaweedfs-host` |
| Pod | `/mnt/ganesha-seaweedfs/data` | Pod Ganesha `172.18.0.2:32049`，pseudo `/seaweedfs` |

两者都写入同一个 SeaweedFS filer 的 `/data`。

## 公平对比检查表

| 项目 | 状态 |
|---|---|
| NFS 客户端 | 同一个 host fio |
| 后端 | 同一个 master/volume/filer/PVC；4 GiB 卷；vacuum 关闭 |
| FUSE 参数 | 相同（64/64 writers/readers、cache 128 MB tmpfs、chunk 8 MB、write buffer 4 GB、`-dlm`、maxBackground 128） |
| Ganesha | 两边都是 15.9；host 配置复制 pod 配置（`RPC_Ioq_ThrdMin=8`、`RPC_Ioq_ThrdMax=200`、Protocols 4、metrics off、Root_Squash、1 MiB） |
| 资源 | Pod limits 已移除；host 不限制；两者共享同一台 host |
| fio | 同一组用例、6G/1G、3 次重复 |
| 清理 | 每个用例后删数据 + 删 filer change log + vacuum |
| NFS 网络 | host 臂是本地 NFS；pod 臂经 NodePort/kube-proxy（这是 placement 本身的差异） |

## 运行 3 次并统计

使用 [user-guide-perf.md](user-guide-perf.md) 的 `run_three`，分别设置：

```bash
# host arm
TESTDIR=/mnt/ganesha-host-arm/data/manual-$(date +%Y%m%d-%H%M%S)
mkdir -p "$TESTDIR"

# pod arm
TESTDIR=/mnt/ganesha-seaweedfs/data/manual-$(date +%Y%m%d-%H%M%S)
mkdir -p "$TESTDIR"
```

然后分别执行：

```bash
run_three buffered-1m   1M 0 1 6G
run_three odirect-1m    1M 1 1 6G
run_three odirect-8m    8M 1 1 6G
run_three buffered-8job 1M 0 8 1G
```

Host 臂结束后先清理并 vacuum，再跑 Pod 臂；两个臂不能同时对同一个 filer/volume 做性能测试。

## 实测结果（24 GiB buffered 写）

| 臂 | 基线 | 当前最佳配置 |
|---|---:|---:|
| Host | 80.9 MiB/s | 394–439 MiB/s（单次样本，clat ~65–72 ms） |
| Pod | 82.4 MiB/s | 343–394 MiB/s |

当前最佳配置：Ganesha `RPC_Ioq_ThrdMax=200`、FUSE writers/readers 64/64、chunk 8 MB、tmpfs cache、
`writeBufferSizeMB=4096`、`dirty_bytes=2 GiB`、后端 CPU limits 移除。
完整参数与复现步骤见 [performance-parameters.md](performance-parameters.md)。

## 清理

```bash
# 1) 删除本次数据
rm -rf "$TESTDIR"
sync

# 2) 删除 filer change log（FUSE 导出中不可见）
printf 'fs.rm -r /topics/.system/log/%s\nexit\n' "$(date +%F)" | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
  /usr/local/bin/weed shell -master=172.18.0.2:9333

# 3) vacuum
printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333
```

轮询 `.dat` 总量直到稳定。本环境实测：删除全部测试数据 + change log 后，`123.83 GiB → 0.008 GiB`（仅空卷开销）。

## 注意事项

- 两个臂串行运行，不能同时对同一 filer/volume 做性能测试。
- Host 臂的 fio 与 Ganesha/FUSE 在同一台 host，存在 client/server CPU 竞争；Pod 臂的 server 在 Pod 中，但也在同一 kind node 上。这属于 placement 差异的一部分，报告中注明。
- Host 臂的 `/home/ys1000/seaweedfs/mnt-k8s` 必须**先 FUSE mount，再启动 host Ganesha**（R10）；脚本已按此顺序。
- host Ganesha 的 `NFS_Port=2049`；Pod 臂的 NFS 是 NodePort 32049。
- host Ganesha 启动/停止只影响 host 臂，不会动 K8s；`host-arm-ganesha-seaweedfs.sh down` 不会删除 Pod 或 PVC。
- 不要直接删除或修改 `.dat` / `.idx`；数据删除通过 NFS/filer，空间回收用 `volume.vacuum`。
- 本方案的 node IP 固定为 `172.18.0.2`（kind 单节点）；换集群时需要同步修改 manifest 和脚本中的地址。
