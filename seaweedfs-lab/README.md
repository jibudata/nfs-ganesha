## Additional Kubernetes benchmark arm

The optional [Ganesha + FUSE Pod arm](GANESHA-FUSE-POD.md) places the SeaweedFS FUSE mount and NFS-Ganesha in separate containers in the same Pod, exposes NFSv4.1 through a fixed MetalLB LoadBalancer address, and runs fio from the host.
