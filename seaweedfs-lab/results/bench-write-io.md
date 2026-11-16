# NFS-Ganesha V15.9 → FUSE (SeaweedFS) Write I/O Matrix

Host: ys1000@192.168.3.146 (Ubuntu 24.04, 16 vCPU, NVMe /dev/nvme0n1p3)
Chain: NFS client → ganesha.nfsd (FSAL_VFS) → fuse.seaweedfs → weed filer → weed volume → NVMe
Client and server are on the SAME host; NFS traffic uses the local br0 address
and never crosses the 1 GbE physical NIC.

Generated: 2026-11-16T09:46:14+00:00

| case | MiB/s | IOPS | io_err | avg WRITE lat (ms) | rpc/s | WRITE ops | ganesha CPU (s) | weed mount CPU (s) | .dat delta (MiB) |
|---|---|---|---|---|---|---|---|---|---|
| `rep1_1M_1job` | 120 | 119 | 0 | 131.835 | 85.0 | 1024.000000 | .7 | 5.2 | 1040 |
| `rep2_1M_1job` | 131 | 130 | 0 | 120.689 | 125.3 | 1024.000000 | .7 | 4.6 | 1045 |
| `rep3_1M_1job` | 126 | 125 | 0 | 125.452 | 121.0 | 1024.000000 | .7 | 4.9 | 1044 |
| `nfs41_1M_1job` | 101 | 100 | 0 | 157.652 | 99.0 | 2048.000000 | 1.4 | 12.5 | 2138 |
| `nfsv3_1M_1job` | 104 | 103 | 0 | 0 | 102.5 | 0.000000 | 1.4 | 12.3 | 2139 |
| `nfs41_128k_1job` | 23.7 | 189 | 0 | 83.736 | 188.9 | 16384.000000 | 3.0 | 20.1 | 2091 |
| `nfs41_256k_1job` | 44.7 | 178 | 0 | 88.728 | 177.4 | 8192.000000 | 2.3 | 17.7 | 2075 |
| `nfs41_512k_1job` | 66.1 | 132 | 0 | 119.930 | 130.8 | 4096.000000 | 1.7 | 15.3 | -2312 |
| `nfs41_ws262144_256k` | 47.8 | 191 | 0 | 82.986 | 189.3 | 8192.000000 | 2.2 | 16.4 | -5149 |
| `nfs41_ws524288_512k` | 65.4 | 130 | 0 | 121.249 | 129.5 | 4096.000000 | 1.8 | 15.6 | -726 |
| `nfs41_ws1048576_1M` | 98.8 | 98 | 0 | 160.287 | 97.5 | 2048.000000 | 1.4 | 12.6 | 2138 |
| `nfs41_1M_2job` | 279 | 287 | 0 | 109.282 | 265.0 | 2048.000000 | 1.3 | 8.4 | 2094 |
| `nfs41_1M_4job` | 473 | 482 | 0 | 122.715 | 453.1 | 4096.000000 | 2.6 | 18.1 | 872 |
| `nfs41_1M_8job` | 761 | 772 | 0 | 76.739 | 711.9 | 4096.000000 | 3.0 | 17.9 | 4133 |
| `nfs41_buffered` | 2547 | 2547 | 0 | 21.596 | 640.4 | 2048.000000 | 1.5 | 5.5 | 2051 |
| `nfs41_odirect` | 104 | 103 | 0 | 153.033 | 101.9 | 2048.000000 | 1.3 | 11.5 | 2142 |
| `nfs41_fdatasync` | 76.7 | 76 | 0 | 11.466 | 75.6 | 1024.000000 | .7 | 7.0 | 1063 |
| `fuse_1M_odirect` | 1952 | 1952 | 0 | 0 | 0 | 0.000000 | 0 | 4.8 | 2048 |
| `fuse_1M_buffered` | 1350 | 1350 | 0 | 0 | 1.0 | 0.000000 | 0 | 4.7 | 2048 |
| `fuse_1M_4job` | 1956 | 1966 | 0 | 0 | 0 | 0.000000 | 0 | 10.6 | 4096 |
| `raw_1M_odirect` | 5278 | 5278 | 0 | 0 | 0 | 0.000000 | 0 | 0 | 0 |
| `raw_1M_buffered` | 3185 | 3185 | 0 | 0 | 1.9 | 0.000000 | 0 | 0 | 0 |

Notes:
- `avg WRITE lat` is Ganesha-side NFSv4 WRITE latency from Prometheus
  (`nfsv4__op_latency_sum / nfsv4__op_latency_count`), in ms, summed over all status labels.
  It is 0 for the NFSv3 case because those metrics are NFSv4-only.
- `.dat delta` is the change in total volume-server `.dat` size over the case.
  It can be NEGATIVE: SeaweedFS reclaims/compacts volume files while a case runs,
  so it is a rough 'data that reached the volume server' indicator, not a byte counter.
- `ganesha CPU` / `weed mount CPU` are process CPU seconds (utime+stime) consumed
  during the case.
