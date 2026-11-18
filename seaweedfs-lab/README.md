## Additional Kubernetes benchmark arm

The optional [Ganesha + FUSE Pod arm](GANESHA-FUSE-POD.md) runs the SeaweedFS FUSE mount and NFS-Ganesha in one container, exposes NFSv4.1 through a fixed MetalLB LoadBalancer address, and runs fio from the host.

## Self-contained local test stack

The [ganesha-seaweedfs namespace](k8s/ganesha-seaweedfs/README.md) deploys the full SeaweedFS storage plane with node-IP hostPorts (no MetalLB), plus the pod-arm FUSE mount and Ganesha, exposed over a NodePort. Drive it with `scripts/k8s-ganesha-seaweedfs.sh up|status|test|down`.

The same backend can be served by a host Ganesha/FUSE arm with `scripts/host-arm-ganesha-seaweedfs.sh up|status|down`; the two-arm procedure and fairness checklist are in [docs/host-vs-pod-comparison.md](../docs/host-vs-pod-comparison.md). The manual performance-test guide is [docs/user-guide-perf.md](../docs/user-guide-perf.md).
