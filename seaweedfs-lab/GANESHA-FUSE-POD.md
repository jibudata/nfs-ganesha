## Ganesha + FUSE in one Pod, host-side fio

This adds an experimental comparison arm without changing the existing bare-metal, Docker, or storage-plane Kubernetes arms:

```text
host fio -> NFSv4.1/TCP LoadBalancer -> Ganesha container
         -> SeaweedFS FUSE mount, same container -> filer/volume Pods
```

The FUSE mount and the Ganesha server live in **one container** (image
`seaweedfs-lab:ganesha-v15.9`, see `k8s/ganesha-entrypoint.sh`), so the export
Ganesha serves is the FUSE mount itself — one mount namespace, no
cross-container mount propagation involved.  An earlier two-container layout
(FUSE sidecar + `Bidirectional`/`HostToContainer` propagation) never received
the submount on Kind, which is why the design was collapsed.  The container is
privileged and needs the node's `/dev/fuse`.

The example reserves MetalLB address `172.18.255.53`; add it to the cluster's advertised pool before deploying. The Service exposes only TCP/2049 because this arm is pinned to NFSv4.1 (no NFSv3 mountd/rpcbind ports).

Build the image from this checkout so it matches the Ganesha source revision; the helper stages the pinned SeaweedFS `weed` binary into the build context first:

```bash
bash seaweedfs-lab/scripts/k8s-build-ganesha-image.sh
```

Deploy the storage arm and this manifest:

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
