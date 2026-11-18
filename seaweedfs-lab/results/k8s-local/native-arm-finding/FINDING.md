# VM-native (non-K8s) arm: root cause found — configuration, now fixed. 2026-11-18

The same Ganesha V15.9 + weed 4.54 stack was run as plain processes
inside the colima VM (no docker, no K8s) to compare against the K8s pod
arm: master/volume/filer on 127.0.0.1:19350-19354, weed FUSE mount at
/mnt/lima-colima/native-arm/mnt (concurrentWriters/Readers=16, same
flags as the pod), Ganesha NFS on 0.0.0.0:20490, export /seaweedfs.

## First attempts failed: two configuration problems (both fixed)

1. **The volume server was started without `-master.peers`**, so it
   never registered with the master: master log showed
   "topo failed to pick 1 from 0 node candidates — Not enough data
   nodes found!".  With zero data nodes every AssignVolume hung, the
   weed mount's uploads failed asynchronously ("assign volume: call
   timed out"), NFS writes were accepted by the page cache and then
   silently lost (fio rc=0, file stuck at ~1 GiB, filer file_count=0).
   Fix: add `-master.peers=127.0.0.1:19350` (the K8s manifest always
   had it; the native script missed it).

2. **After a master restart with rebuilt state, volume growth stays
   frozen** ("volume growth is frozen after master state loss") — a
   safety feature of this fork.  Every AssignVolume from a still-alive
   filer/mount then hangs, producing the same silent-loss signature.
   Fix: `volume.growth.resume` via weed shell; now baked into the arm's
   start script so it runs on every start.

With both fixed the arm is fully operational: VM-direct FUSE writes
land exactly (128 MiB probe → 128.0 MiB in .dat), NFS writes from the
node land (64 MiB probe), and the full small-size mode matrix ran
clean (buffer 284 / fsync16 309 / fsync1 817 / odirect-1m 606 MiB/s,
all landing-verified; see the paired comparison below and
RESULTS.zh.md).

## Headline paired comparison

Same VM, same kernel NFS client, same fio, sequential 1 MiB O_DIRECT,
1.5 GiB:

| arm | throughput |
|---|---|
| VM-native processes (no docker, no K8s) | **606 MiB/s** |
| K8s pod arm (NFS via NodePort 32049) | 40.8 MiB/s |

buffer-mode paired point (1.5 GiB native vs 10 GiB K8s): 284 vs
43.6-48.8 MiB/s.  The pod layer plus the in-cluster storage placement
(filer/volume pods over ClusterIP instead of localhost processes) costs
an order of magnitude on this workload in this environment; per-op
latency compounding through NFS→Ganesha→FUSE→weed→filer→volume is the
suspected driver, not bandwidth (the Service layer itself measured
zero: see net-ladder.txt).

## Residual caveats

- Sustained (>2 GiB) NFS writes into the native arm can still wedge the
  mount→filer grpc chain on this small VM (three episodes observed;
  D-state pile-up with load 25-59 while disk and master stay
  responsive).  Recovery = FUSE abort + restart of weedmount/ganesha.
  The K8s pod arm never wedged across all runs; suspected cause is the
  unbounded native mount buffering on a 8 GiB VM (the pod's cgroup cap
  acts as pacing).  Needs weed-level goroutine dumps to pin down.
- After restarting ganesha or the weed mount, NFS clients must be
  remounted (stale handles) — standard NFSv4 behaviour, and R10 for the
  ganesha-after-mount ordering.

## Provenance

Scripts: /mnt/lima-colima/native-arm/native-arm-setup.sh (on the VM;
start embeds the growth-resume fix).  Logs from the failed era in
logs/.  Raw fio outputs of the working runs:
/home/jibu.guest/mode-matrix-native-small/ on the VM, mirrored in
seaweedfs-lab/results/k8s-local/.
