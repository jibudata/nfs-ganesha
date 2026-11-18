# Mid-config sequential protocol results (8 vCPU colima, 2026-11-18)

Config: K8s pod arm, single-container Ganesha+FUSE, "local-tuned" values
between the base (16/16/2) and the 16 vCPU tuned (128/64/8):
  CONCURRENT_WRITERS/READERS=32, CHUNK_SIZE_LIMIT_MB=8,
  WRITE_BUFFER_SIZE_MB=1024 (was 4096 - the 4 GiB buffer on an 8 GiB VM
  was the wedge amplifier), RPC_Ioq_ThrdMax=32.
  Pod limits: ganesha-fuse 4 CPU/6 Gi, filer 8 CPU/8 Gi, volume 8 CPU/8 Gi.
Client: VM kernel NFS client over NodePort 32049 (same host).

Protocol (strict, sequential, per case):
  one fio only -> complete -> landing check (mawk-safe, settle <=300 s)
  -> stop fio -> rm test file -> volume.vacuum -garbageThreshold=0.01
  on the master -> .dat verified back at baseline -> next case.

## Results (1.5 GiB per case, all landing-verified)

| mode        | K8s arm (mid cfg) | VM-native arm (ref) | gap   |
|-------------|-------------------|---------------------|-------|
| buffer-1m   | 313 MiB/s         | 284 MiB/s           | parity (K8s +10%) |
| fsync16-1m  | 72.1 MiB/s        | 309 MiB/s           | 4.3x  |
| odirect-1m  | 29-30.1 MiB/s     | 606 MiB/s           | ~20x  |

## Findings

1. The buffered-mode gap to the native arm is CLOSED (313 vs 284): the
   1 GiB write buffer paces the pipeline correctly on this VM, where the
   4 GiB default caused memory-pressure wedges.
2. The sync-path gap (fsync16, odirect) remains 4-20x: forced-sync
   writes are bound by the per-chunk upload drain through the pod
   network (mount -> filer -> volume over ClusterIP).  Removing the
   backend pod CPU limits (filer 4->8, volume 4->8) changed odirect by
   <4% - CPU is not the bottleneck.
3. Next optimization lever for sync modes: upload drain rate (chunk
   size already 8 MiB; try more upload workers for the sync flush path,
   or hostNetwork placement of the storage plane on single-node rigs).
4. Volume.vacuum -garbageThreshold=0.01 between cases reclaimed the
   test footprint (40+ GiB dead .dat -> 2.4 GiB) and is required - the
   K8s master has vacuum disabled at runtime for measurement hygiene.

Runner: k8s-single-case-runner.sh (executes ONE fio per invocation;
refuses to start if another fio is alive).
