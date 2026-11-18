## Additional Kubernetes benchmark arm

The optional [Ganesha + FUSE Pod arm](GANESHA-FUSE-POD.md) runs the SeaweedFS FUSE mount and NFS-Ganesha in one container, exposes NFSv4.1 through a fixed MetalLB LoadBalancer address, and runs fio from the host.

## Self-contained local test stack

The [ganesha-seaweedfs namespace](k8s/ganesha-seaweedfs/README.md) deploys the full SeaweedFS storage plane, the FUSE mount and Ganesha in one namespace, exposed over a NodePort. It needs no MetalLB and no fixed addresses; drive it with `scripts/k8s-ganesha-seaweedfs.sh up|status|test|down`.
