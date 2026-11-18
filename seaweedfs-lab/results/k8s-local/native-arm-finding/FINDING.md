# VM-native (non-K8s) arm: unstable NFS write path — finding, 2026-11-18

The same Ganesha V15.9 + weed 4.54 stack was run as plain processes
inside the colima VM (no docker, no K8s) to compare against the K8s pod
arm: master/volume/filer on 127.0.0.1:19350-19354, weed FUSE mount at
/mnt/lima-colima/native-arm/mnt (concurrentWriters/Readers=16, same
flags as the pod), Ganesha NFS on 0.0.0.0:20490, export /seaweedfs.

## What worked
- VM-direct FUSE writes (root, on the VM): 75-146 MB/s bursts, landed
  and verified in the volume .dat files.
- The first ~1 GiB of an NFS-buffered 10 GiB case (19.2 MiB/s), then
  uploads stalled.

## What failed
- NFS-initiated writes silently lose data: fio reports rc=0 and full
  bytes written, but the file on the FUSE mount stays at ~1 GiB, the
  filer reports file_count:0, and the volume server registers no
  volumes.  weedmount.log shows thousands of repeated upload errors
  ("assign volume ... call timed out" then "use of closed network
  connection" spam, 9285 lines) without recovery.  Subsequent access to
  affected files returns ESTALE.
- One contributing infra bug was fixed along the way: the volume server
  was started without -master.peers, so it never registered with the
  master ("topo failed to pick 1 from 0 node candidates"); registering
  fixed volume allocation, but the mount-side connection breakage
  remained.

## Interpretation
The K8s pod arm ran the identical workload (same client, same VM, same
disk, same weed/ganesha builds, writes as NFS nobody through
Root_Squash) five times for 10 GiB each without a single lost write or
connection drop.  The instability is specific to running the mount +
filer pair as VM processes in this environment (root, localhost grpc,
no container), not to the K8s layers.

Status: arm stopped, scripts kept at
/mnt/lima-colima/native-arm/native-arm-setup.sh, logs in this
directory.  Not usable for measurement until the mount->filer grpc
connection drops under sustained NFS load are root-caused.
