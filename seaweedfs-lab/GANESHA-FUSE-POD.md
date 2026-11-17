## Ganesha + FUSE in one Pod, host-side fio

This adds an experimental comparison arm without changing the existing bare-metal, Docker, or storage-plane Kubernetes arms:

```text
host fio -> NFSv4.1/TCP LoadBalancer -> Ganesha container
         -> SeaweedFS FUSE sidecar in the same Pod -> filer/volume Pods
```

The FUSE and Ganesha containers share an `emptyDir` mountpoint. The FUSE sidecar uses bidirectional mount propagation and the Ganesha container receives propagated mounts (`HostToContainer`). This requires a Kubernetes/container runtime that supports mount propagation; the FUSE container is privileged and needs the node's `/dev/fuse`.

The example reserves MetalLB address `172.18.255.53`; add it to the cluster's advertised pool before deploying. The Service exposes only TCP/2049 because this arm is pinned to NFSv4.1 (no NFSv3 mountd/rpcbind ports).

Build the image from this checkout so it matches the Ganesha source revision:

```bash
bash seaweedfs-lab/scripts/k8s-build-ganesha-image.sh
```

Make the SeaweedFS image (`seaweedfs-lab:4.54`) available in the Kubernetes node runtime using the existing `k8s-build-image.sh` flow, then deploy the storage arm and this manifest:

```bash
bash seaweedfs-lab/scripts/k8s-build-image.sh
kubectl apply -f seaweedfs-lab/k8s/
kubectl -n seaweedfs rollout status deploy/seaweedfs-ganesha-fuse
```

Run fio on the host. The script mounts the NFS export if needed and checks that non-zero test data reaches the volume server before accepting each result:

```bash
bash seaweedfs-lab/scripts/bench-k8s-ganesha-fuse.sh
```

The benchmark host must be able to reach the MetalLB address, have `kubectl` access for the `.dat` landing check, and run a fio 3.36-compatible binary. The sample script tests buffered 1 MiB, O_DIRECT 1/8 MiB, and buffered eight-job workloads; it leaves the NFS mount in place for inspection. This is a new benchmark arm, not a result claim: measure it against the existing host-Ganesha baseline under the same backend, client, workload, and network conditions.
