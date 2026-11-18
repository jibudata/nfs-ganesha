# Local colima/kind write measurements (attribution study)

Environment: colima VM (Virtualization.framework, aarch64) running a
single-node kind cluster (kindest/node:v1.32.0).  The arm under test is
the single-container Ganesha+FUSE pod (`50-ganesha-fuse.yaml`); the NFS
client is the kind node's kernel client over NodePort 32049.

These numbers are from a NESTED desktop environment (shared macOS host,
4->8 vCPU, virtiofs disk) and carry a +/-30-40% single-run noise band.
They are for LAYER ATTRIBUTION only, not performance claims - cross-arm
comparisons belong to the bare-metal lab matrix (RESULTS.md).

Files:
- results-8vcpu-threads16.csv      main 3-mode matrix, 8 vCPU, IO threads 16
- results-8vcpu-buffer-dirtycap.csv buffer case after vm.dirty_bytes=2GiB (+104%)
- results-buffer-1m-nolimit.csv    buffer case with pod CPU limit removed (+53%)
- results-4vcpu-*.csv              4 vCPU reference points (threads 128, noisy)
- net-ladder.txt                   iperf3 Service-layer ladder
- fio-raw/                         raw fio output and job files

Full analysis: seaweedfs-lab/RESULTS.zh.md (layered attribution, R35
transfer to K8s, the vm.dirty_bytes finding, IO-thread cap rationale).
