# Ganesha + SeaweedFS 性能测试指南（宿主机 NFS 客户端）

> 适用环境：本地 Kind 集群，命名空间 `ganesha-seaweedfs`
> 更新日期：2026-11-18
> 目标：在宿主机上用 NFSv4.1 挂载 Ganesha 导出的 SeaweedFS FUSE 目录，用 fio 执行可重复的写性能测试，并在测试后清理数据、回收 SeaweedFS 空间。

## 目录

- [1. 架构与前提](#1-架构与前提)
- [2. 快速开始](#2-快速开始)
- [3. 检查服务端确实在 K8s Pod 内](#3-检查服务端确实在-k8s-pod-内)
- [4. 获取 Node IP / NodePort](#4-获取-node-ip--nodeport)
- [5. 宿主机挂载 NFSv4.1](#5-宿主机挂载-nfsv41)
- [6. 准备测试目录与 fio](#6-准备测试目录与-fio)
- [7. 单个用例的 fio 配置](#7-单个用例的-fio-配置)
- [8. 每个用例运行 3 次并统计](#8-每个用例运行-3-次并统计)
- [9. 标准测试矩阵](#9-标准测试矩阵)
- [10. 结果解读](#10-结果解读)
- [11. 落盘校验](#11-落盘校验)
- [12. 删除数据并回收空间](#12-删除数据并回收空间)
- [13. 卸载](#13-卸载)
- [14. 数据实际位置](#14-数据实际位置)
- [15. 常见问题](#15-常见问题)

## 1. 架构与前提

```text
宿主机 fio
  └─ NFSv4.1 客户端 (/mnt/ganesha-seaweedfs)
       └─ NodePort 32049
            └─ Ganesha Pod ── weed FUSE (/mnt/seaweedfs)
                 └─ filer Pod ── volume Pod (/data/vol) ── master Pod
```

- **只有 NFS 客户端（fio）运行在宿主机**；Ganesha、weed FUSE、filer、volume、master 全部在 K8s Pod 内。
- 命名空间：`ganesha-seaweedfs`。
- SeaweedFS 卷大小上限：**4096 MiB（4 GiB）**。
- 每个单 job 用例建议写 6 GiB，确保跨越多个 4 GiB 卷；8 job 用例为 8 × 1 GiB。
- 宿主机需要：`mount.nfs`（nfs-common）、`fio 3.36`（`/usr/local/bin/fio`）、`kubectl`、`sudo`。

## 2. 快速开始

```bash
cd /home/ys1000/src/github.com/jibudata/nfs-ganesha

# 1) 挂载
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl -n ganesha-seaweedfs get svc seaweedfs-ganesha-fuse \
  -o jsonpath='{.spec.ports[?(@.name=="nfs")].nodePort}')
sudo mkdir -p /mnt/ganesha-seaweedfs
sudo mount -t nfs \
  -o vers=4.1,proto=tcp,port=${NODE_PORT},rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  ${NODE_IP}:/seaweedfs /mnt/ganesha-seaweedfs

# 2) 建测试目录
TESTDIR=/mnt/ganesha-seaweedfs/data/manual-$(date +%Y%m%d-%H%M%S)
mkdir -p "$TESTDIR"

# 3) 6 GiB 写测试（详见第 7 节）
NAME="manual-$(date +%Y%m%d-%H%M%S)-buf1m"
cat > /tmp/ganesha-write.fio <<EOF
[global]
ioengine=libaio
rw=write
bs=1M
direct=0
iodepth=16
size=6G
fallocate=none
end_fsync=1
scramble_buffers=1
directory=$TESTDIR
filename_format=$NAME.\$jobnum
group_reporting=1

[$NAME]
numjobs=1
EOF
/usr/local/bin/fio /tmp/ganesha-write.fio

# 4) 清理 + 回收（详见第 12 节）
rm -rf "$TESTDIR"
sync
# filer 的 change log 也占 volume chunk，且 FUSE 导出中不可见
printf 'fs.rm -r /topics/.system/log/%s\nexit\n' "$(date +%F)" | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
  /usr/local/bin/weed shell -master=seaweedfs-master:9333 >/dev/null 2>&1 || true
printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333
```

## 3. 检查服务端确实在 K8s Pod 内

```bash
kubectl -n ganesha-seaweedfs get pods -o wide

kubectl -n ganesha-seaweedfs exec deploy/seaweedfs-ganesha-fuse -- \
  ps -ef | grep -E 'weed mount|ganesha.nfsd'

kubectl -n ganesha-seaweedfs exec deploy/seaweedfs-ganesha-fuse -- \
  awk '$2 == "/mnt/seaweedfs" {print}' /proc/mounts
```

预期：

```text
/usr/local/bin/weed mount -filer=seaweedfs-filer... -dir=/mnt/seaweedfs ...
/usr/bin/ganesha.nfsd -F -f /etc/ganesha/ganesha.conf ...
seaweedfs-ganesha-pod /mnt/seaweedfs fuse.seaweedfs rw,...
```

> 宿主机 `ps` 里可能也能看到这些进程，是因为 kind 节点容器与宿主机共享 PID 视图；以 Pod 内的 `kubectl exec` 结果为准。

## 4. 获取 Node IP / NodePort

```bash
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

NODE_PORT=$(kubectl -n ganesha-seaweedfs get svc seaweedfs-ganesha-fuse \
  -o jsonpath='{.spec.ports[?(@.name=="nfs")].nodePort}')

echo "$NODE_IP:$NODE_PORT"
```

当前环境通常为 `172.18.0.2:32049`。

## 5. 宿主机挂载 NFSv4.1

```bash
sudo mkdir -p /mnt/ganesha-seaweedfs

sudo mount -t nfs \
  -o vers=4.1,proto=tcp,port=${NODE_PORT},rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  ${NODE_IP}:/seaweedfs /mnt/ganesha-seaweedfs
```

检查（不要用 `mountpoint`/`stat`，读 `/proc/mounts`）：

```bash
awk '$2 == "/mnt/ganesha-seaweedfs" {print}' /proc/mounts
```

预期：

```text
172.18.0.2:/seaweedfs /mnt/ganesha-seaweedfs nfs4 rw,vers=4.1,rsize=1048576,wsize=1048576,...
```

参数说明：

| 参数 | 含义 |
|---|---|
| `vers=4.1` | NFSv4.1；服务端只启用 NFSv4（`Protocols = 4`），不需要 rpcbind/mountd |
| `proto=tcp` | 仅 TCP |
| `port=${NODE_PORT}` | 通过 Service 的 NodePort 访问；Pod IP 在宿主机不可路由 |
| `rsize/wsize=1048576` | 1 MiB 读写块 |
| `hard,timeo=600,retrans=2` | 硬挂载；服务端异常时客户端会重试而不是静默丢写 |

> 如果已经挂载，可跳过本节。Ganesha Pod 重启后已有挂载会失效，需要重新挂载。

### 目录与权限

```bash
ls -ld /mnt/ganesha-seaweedfs /mnt/ganesha-seaweedfs/data
```

- 导出根是 `Root_Squash`，不要直接写根目录。
- 写 `/mnt/ganesha-seaweedfs/data`（`0777`）。
- 文件属主显示为 `nobody` 是 NFSv4 ID 映射和 Root_Squash 的正常现象。

## 6. 准备测试目录与 fio

每个用例建独立目录，便于精确清理：

```bash
TESTDIR=/mnt/ganesha-seaweedfs/data/manual-$(date +%Y%m%d-%H%M%S)
mkdir -p "$TESTDIR"

/usr/local/bin/fio --version
```

预期输出 `fio-3.36`。fio 用普通用户运行即可，**不需要 sudo**；只有 mount/umount 需要 sudo。

## 7. 单个用例的 fio 配置

```bash
NAME="manual-$(date +%Y%m%d-%H%M%S)-buf1m"
BS=1M        # 块大小
DIRECT=0     # 0=缓冲写，1=O_DIRECT
JOBS=1       # numjobs
SIZE=6G      # 每个 job 写 6 GiB，超过 4 GiB 卷上限

cat > /tmp/ganesha-write.fio <<EOF
[global]
ioengine=libaio
rw=write
bs=$BS
direct=$DIRECT
iodepth=16
size=$SIZE
fallocate=none
end_fsync=1
scramble_buffers=1
directory=$TESTDIR
filename_format=$NAME.\$jobnum
group_reporting=1

[$NAME]
numjobs=$JOBS
EOF

/usr/local/bin/fio /tmp/ganesha-write.fio
```

参数说明：

| 参数 | 作用 |
|---|---|
| `ioengine=libaio` | 异步 IO，与基准脚本一致 |
| `rw=write` | 纯写测试 |
| `bs` | 块大小（1M / 8M） |
| `direct=0/1` | 缓冲写 / O_DIRECT |
| `iodepth=16` | 队列深度 |
| `size=6G` | **每个 job** 写 6 GiB |
| `fallocate=none` | 不预分配 |
| `end_fsync=1` | fio 结束时强制刷盘，便于落盘校验 |
| `scramble_buffers=1` | 写非零数据；SeaweedFS 把全零块存成引用，`.dat` 不会增长 |
| `group_reporting=1` | 输出 group 汇总；统计时取 `WRITE: bw=` 行 |
| `numjobs` | 并发 job 数 |

> `filename_format=$NAME.\$jobnum` 中的反斜杠不能去掉，否则 shell 会先把 `$jobnum` 展开成空。

## 8. 每个用例运行 3 次并统计

约定：**一个“测试”= 一个用例；每个用例跑 3 次，3 次结束后删除该用例数据并 vacuum。**

```bash
run_three() {
  local name=$1 bs=$2 direct=$3 jobs=$4 size=$5
  local tag="manual-$(date +%Y%m%d-%H%M%S)-$$-$name"
  local r rc

  for r in 1 2 3; do
    cat > "/tmp/${tag}-r${r}.fio" <<EOF
[global]
ioengine=libaio
rw=write
bs=$bs
direct=$direct
iodepth=16
size=$size
fallocate=none
end_fsync=1
scramble_buffers=1
directory=$TESTDIR
filename_format=${tag}-r${r}.\$jobnum
group_reporting=1

[${tag}-r${r}]
numjobs=$jobs
EOF

    /usr/local/bin/fio "/tmp/${tag}-r${r}.fio" \
      | tee "/tmp/${tag}-r${r}.log" \
      | grep -E 'WRITE: bw='
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || echo "WARN: fio rc=$rc (run ${r})"
  done

  echo "=== ${name}: 3 次带宽统计（MiB/s） ==="
  grep -h 'WRITE: bw=' "/tmp/${tag}-r"*.log \
    | sed -E 's/.*bw=([0-9.]+)([KMG])iB\/s.*/\1 \2/' \
    | awk '
        { v=$1
          if ($2=="KiB") v/=1024
          else if ($2=="GiB") v*=1024
          a[NR]=v; s+=v }
        END {
          if (NR==0) { print "no runs"; exit }
          n=NR; m=s/n; min=a[1]; max=a[1]
          for (i=1;i<=n;i++) {
            if (a[i]<min) min=a[i]
            if (a[i]>max) max=a[i]
            d=a[i]-m; ss+=d*d
          }
          printf "runs=%d mean=%.1f min=%.1f max=%.1f spread=%.1f stdev=%.1f\n",
                 n, m, min, max, max-min, sqrt(ss/n)
        }'

  # 删除该用例数据
  rm -rf "$TESTDIR/${tag}-r"*
  sync

  # 清理 filer change log（/topics 在 FUSE 导出中不可见）
  printf 'fs.rm -r /topics/.system/log/%s\nexit\n' "$(date +%F)" | \
    kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
    /usr/local/bin/weed shell -master=seaweedfs-master:9333 >/dev/null 2>&1 || true

  # 手动 vacuum（必须先 lock）
  printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
    kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
    /usr/local/bin/weed shell -master=127.0.0.1:9333

  echo "清理已提交；用第 12 节命令等待 .dat 大小稳定"
}
```

> 3 次运行都在同一个用例内连续执行，vacuum 在 3 次全部结束后进行。这样前两次产生已删除 chunk 不会立即回收，但不会影响写入吞吐（4 GiB 卷池仍有足够空间）。如果要求每次运行前都完全干净，可把删除 + vacuum 移入 `for` 循环内，代价是每次多一次 compaction。

## 9. 标准测试矩阵

```bash
run_three buffered-1m   1M 0 1 6G   # 6 GiB，缓冲写
run_three odirect-1m    1M 1 1 6G   # 6 GiB，O_DIRECT
run_three odirect-8m    8M 1 1 6G   # 6 GiB，O_DIRECT，大块
run_three buffered-8job 1M 0 8 1G   # 8 × 1 GiB = 8 GiB
```

| 用例 | bs | direct | numjobs | 每个 job 大小 | 总写入 |
|---|---|---|---|---|---|
| buffered-1m | 1M | 0 | 1 | 6G | 6G |
| odirect-1m | 1M | 1 | 1 | 6G | 6G |
| odirect-8m | 8M | 1 | 1 | 6G | 6G |
| buffered-8job | 1M | 0 | 8 | 1G | 8G |

总写入量约 26 GiB。每个单 job 用例的 6 GiB > 4 GiB 卷上限，因此会跨多个 SeaweedFS 卷。

## 10. 结果解读

fio 输出中只看 **group 汇总行**：

```text
Run status group 0 (all jobs):
  WRITE: bw=201MiB/s (211MB/s), 201MiB/s-201MiB/s (211MB/s-211MB/s), io=6144MiB (6442MB), run=...
```

- `WRITE: bw=`：整体吞吐量。
- 上方 `clat (usec): ... avg=...`：完成延迟；单位写在括号里（`usec`/`msec`/`nsec`）。
- 有 `numjobs` 时，不要取每个 job 的单独行；`WRITE:` 是 group 汇总。
- O_DIRECT 1M 通常明显低于 8M 和缓冲写，这是小块同步路径的正常表现。
- 第 8 节的统计输出示例：

```text
runs=3 mean=201.5 min=176.0 max=227.0 spread=51.0 stdev=25.5
```

## 11. 落盘校验

fio 的带宽是客户端视角；还需要确认数据真的到达 volume server 的 `.dat`：

```bash
REPO=/home/ys1000/src/github.com/jibudata/nfs-ganesha

before=$(K8S_NS=ganesha-seaweedfs bash "$REPO/seaweedfs-lab/scripts/k8s-volume-datsize.sh")
# 运行 fio ...
after=$(K8S_NS=ganesha-seaweedfs bash "$REPO/seaweedfs-lab/scripts/k8s-volume-datsize.sh")
echo "landed: $(( (after - before) / 1048576 )) MiB"
```

- 有效用例的增量至少约为写入量的一半；通常会略大于写入量（4 GiB 卷/chunk 开销）。
- 必须是**非零数据**；`/dev/zero` 会被 SeaweedFS 存成引用，`.dat` 不增长。
- 等待异步 flush 完成再测量；`end_fsync=1` 会缩短等待时间。

查看 4 GiB 卷是否真的滚动：

```bash
printf 'volume.list\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333 | head -30
```

预期首行包含：

```text
Topology volumeSizeLimit:4096 MB hdd(...)
```

新增卷的 `Size` 约为 `4.00G`；一个 6 GiB 用例至少跨两个卷。

## 12. 删除数据并回收空间

删除本次测试目录：

```bash
rm -rf "$TESTDIR"
sync
```

执行 vacuum（**必须先 `lock`**，否则报 `need to run "lock" first`）：

```bash
printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333
```

vacuum 是异步的；轮询 `.dat` 总量，直到稳定：

```bash
K8S_NS=ganesha-seaweedfs bash \
  /home/ys1000/src/github.com/jibudata/nfs-ganesha/seaweedfs-lab/scripts/k8s-volume-datsize.sh \
  | awk '{printf "%.2f GiB\n", $1/1073741824}'
```

每隔几秒执行一次，直到数值不再下降。

本环境一次实测（删除全部测试数据 + filer change log）：`.dat` 总量 **123.83 GiB → 0.008 GiB**；剩余的 8 MiB 是空卷开销。

### filer 的 change log 也占空间

删除测试文件后，如果 `.dat` 仍剩几 GiB，而 `volume.fsck` 报告 `orphan:0`，那通常是 **filer 的 change log**：

```text
/topics/.system/log/<date>/
```

它是 filer 写出的 SeaweedMQ 事件数据。`/topics` **不会出现在 FUSE/NFS 导出中**，所以用 `rm` 删不到；这些 chunk 在 filer 树中仍被引用，因此 fsck 不认为是孤儿，vacuum 也不会回收。

用 filer 的 weed shell 删除，再执行一次 vacuum：

```bash
printf 'fs.rm -r /topics/.system/log/%s\nexit\n' "$(date +%F)" | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
  /usr/local/bin/weed shell -master=seaweedfs-master:9333

printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
  kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-master -- \
  /usr/local/bin/weed shell -master=127.0.0.1:9333
```

> 本环境的 `mq.topic.truncate` / `mq.topic.list` 依赖 MQ broker，当前栈没有部署，会报 `lock broker_balancer not found`；直接用 `fs.rm -r` 删除日期目录即可。

注意：

- 自动 vacuum 在部署时已关闭（`volume.vacuum.disable`），但手动 `volume.vacuum` 仍然有效。
- 如果垃圾比例低于 compaction 阈值，可能不会立即回收；查看 `volume.list` 中的 `DeletedByteCount`。
- **不要直接删除或修改宿主机/Pod 里的 `.dat`、`.idx` 文件**；数据删除请通过 filer/NFS 进行。

## 13. 卸载

```bash
sync
timeout 15 sudo umount -l /mnt/ganesha-seaweedfs
awk '$2 == "/mnt/ganesha-seaweedfs" {print}' /proc/mounts
```

- 使用 `umount -l`（lazy），不要同步 `umount`，避免卡死。
- Ganesha Pod 重启后已有挂载失效，需要重新挂载。

## 14. 数据实际位置

| 层 | 路径 |
|---|---|
| 宿主机 NFS 客户端 | `/mnt/ganesha-seaweedfs/data` |
| Ganesha + FUSE Pod | `/mnt/seaweedfs/data` |
| 逻辑 filer 路径 | `/data/<文件名>` |
| filer change log（FUSE 不可见） | `/topics/.system/log/<date>/` |
| volume Pod（PVC） | `/data/vol/*.dat`、`*.idx` |
| kind 节点内 PV 路径 | `/var/local-path-provisioner/pvc-0fe8..._ganesha-seaweedfs_vol-seaweedfs-volume-0` |
| 宿主机底层目录 | `/var/lib/docker/volumes/b4df5205.../_data/local-path-provisioner/pvc-0fe8...` |

说明：

- 宿主机底层目录需要 `sudo`，且只读查看；不要直接修改 `.dat`/`.idx`。
- 这是 kind 节点的 `/var` Docker volume；PVC 容量（20Gi）只是申请值，local-path 不强制配额。
- 数据操作统一通过 NFS/filer；空间回收用 `volume.vacuum`。

## 15. 常见问题

| 现象 | 排查 |
|---|---|
| `mount.nfs: Connection timed out` | Pod 是否 Ready；NodePort 是否 32049；Node IP 是否正确 |
| `Permission denied` | 不要写导出根；写到 `/data` 下或自建子目录 |
| `direct=1` 报 `EINVAL` | 检查挂载参数和 fio 版本；本环境 O_DIRECT 已验证可用 |
| fio 完成但 `.dat` 不增长 | 等待 flush；确认 `end_fsync=1`、`scramble_buffers=1`；不要写全零 |
| 文件显示 `nobody` | Root_Squash + NFSv4 ID 映射，正常 |
| vacuum 报 `need to run "lock" first` | 先发送 `lock`，再 `volume.vacuum`，最后 `unlock` |
| vacuum 后 `.dat` 没明显下降 | 只有已删除 chunk 会被回收；有效文件仍占空间 |
| vacuum 后仍剩几 GiB，`volume.fsck` 报 `orphan:0` | filer change log（`/topics/.system/log/<date>`）仍引用 chunk；用 filer weed shell 的 `fs.rm -r` 删除后再 vacuum；FUSE 中看不到 `/topics` |
| 宿主机看不到 `/var/local-path-provisioner` | 该路径在 kind 节点容器内；用 `docker exec kagent-control-plane ls ...` 或 Pod 内 `/data/vol` |
