# `ganesha-seaweedfs`: a self-contained Ganesha + SeaweedFS test stack

A local-Kubernetes test environment in its own namespace. It is the
**shared SeaweedFS backend** for two Ganesha/FUSE arms:

- **Pod arm**: Ganesha + weed FUSE in the `seaweedfs-ganesha-fuse` pod.
- **Host arm**: Ganesha + weed FUSE on the host, pointed at the same filer.

The backend advertises the **node IP** and publishes its real ports as
hostPorts, so no MetalLB/LoadBalancer is in the data path:

```text
host/pod FUSE -> 172.18.0.2:8888 filer  (gRPC 18888)
              -> 172.18.0.2:8080 volume (gRPC 18080)
              -> 172.18.0.2:9333 master (gRPC 19333)
```

Both the host and pods reach the node IP, so one backend serves both arms.
The comparison procedure and fairness checklist are in
[host-vs-pod-comparison.md](../../../docs/host-vs-pod-comparison.md).

This is deliberately different from the old benchmark arm in
`seaweedfs-lab/k8s/`, which uses fixed MetalLB addresses; that is a
separate stack.

## What runs

| Object | Kind | Notes |
|---|---|---|
| `seaweedfs-master` | Deployment + PVC + ClusterIP + hostPorts | metadata, 9333/19333 |
| `seaweedfs-volume` | StatefulSet + PVC + ClusterIP + hostPorts | data, 8080/18080, 20 GiB PVC |
| `seaweedfs-filer` | Deployment + PVC + ClusterIP + hostPorts | directory tree, 8888/18888 |
| `seaweedfs-ganesha-fuse` | Deployment + ConfigMap | pod arm: FUSE mount + NFSv4.1 in one container |
| `seaweedfs-ganesha-fuse` Service | NodePort | `2049` -> node port `32049` |
| Host arm (not a K8s object) | host processes | `scripts/host-arm-ganesha-seaweedfs.sh` |

The images are pinned to the lab's SeaweedFS build:

- `seaweedfs-lab:4.54` - master, volume and filer, built from the host's
  own `weed` binary.
- `seaweedfs-lab:ganesha-v15.9` - Ganesha built from this checkout plus
  the same `weed` binary and `fuse3`, running
  `k8s/ganesha-entrypoint.sh`.

## Deploy

```bash
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh up
```

The script checks the node's containerd and builds/imports anything
missing; the Ganesha build is the slow one and is cached by Docker. It
then applies the manifests in order, waits for each rollout, disables the
automatic volume vacuum at runtime, and runs the status checks.

```bash
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh status   # objects + probes
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh test     # end-to-end NFS write
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh down     # delete namespace
```

## Host arm (same backend)

The host arm mounts the same filer/volume hostPorts, then exports the
host FUSE mount through a host Ganesha:

```bash
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh up
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh status
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh down
```

It mounts the FUSE at `/home/ys1000/seaweedfs/mnt-k8s`, starts the host
Ganesha from `host-arm/ganesha.conf` (the same NFS settings as the pod),
and mounts the host NFS client at `/mnt/ganesha-host-arm`. The script
does not modify the K8s stack. See
[the comparison guide](../../../docs/host-vs-pod-comparison.md) for the
run matrix and fairness checklist.

## Endpoints

```text
Pod arm NFS:    <node InternalIP>:/seaweedfs     port 32049
In-cluster NFS: seaweedfs-ganesha-fuse.ganesha-seaweedfs.svc.cluster.local:/seaweedfs
                port 2049
Host arm NFS:   127.0.0.1:/seaweedfs-host       port 2049  (host Ganesha)

Backend (both arms):
  filer   172.18.0.2:8888  (gRPC 18888)
  volume  172.18.0.2:8080  (gRPC 18080)
  master  172.18.0.2:9333  (gRPC 19333)
```

Write into `data/` under the export:

```bash
sudo mkdir -p /mnt/ganesha-seaweedfs-test
sudo mount -t nfs -o vers=4.1,proto=tcp,port=32049 \
  172.18.0.2:/seaweedfs /mnt/ganesha-seaweedfs-test
sudo mkdir -p /mnt/ganesha-seaweedfs-test/data
sudo cp something /mnt/ganesha-seaweedfs-test/data/
```

The export is `Root_Squash` and the FUSE root is owned by root with mode
`0755`, so an NFS client cannot create files at the export root. The
entrypoint creates `data/` mode `0777` (`EXPORT_SUBDIR=data`), which is
where test writes belong.

If the node IP is not routable from your machine, forward the Service
instead; NFSv4 needs only one TCP port:

```bash
sudo kubectl -n ganesha-seaweedfs port-forward \
  --address 0.0.0.0 svc/seaweedfs-ganesha-fuse 2049:2049
sudo mount -t nfs -o vers=4.1,proto=tcp 127.0.0.1:/seaweedfs /mnt/ganesha-seaweedfs-test
```

The master and filer are ClusterIP-only. For direct inspection:

```bash
kubectl -n ganesha-seaweedfs port-forward svc/seaweedfs-master 9333:9333
kubectl -n ganesha-seaweedfs port-forward svc/seaweedfs-filer 8888:8888
kubectl -n ganesha-seaweedfs exec -i deploy/seaweedfs-filer -- \
  /usr/local/bin/weed shell -master=seaweedfs-master:9333
```

## What the test proves

`test` mounts the export on the host through the NodePort, writes 8 MiB
of random data, reads it back and checks the size, then unmounts and
asserts that the volume server's `.dat` files grew. The `.dat` growth is
the load-bearing check (LAB-CONVENTIONS R4): an NFS write can be
acknowledged from cache long before it reaches the storage plane.

## Design notes

- **Shared node-IP hostPorts.** The host arm's FUSE mount must reach the
  filer and the volume server's registered address (R19/R20). All three
  SeaweedFS components register the node IP and publish their real ports
  as hostPorts; the Services stay ClusterIP. hostPort is used instead of
  NodePort because the filer's gRPC is HTTP + 10000 and the volume
  registers its real port, both of which a NodePort translation would
  break. No MetalLB/LoadBalancer is in the data path.
- **Two arms, one backend.** The pod arm is the
  `seaweedfs-ganesha-fuse` Deployment; the host arm is
  `scripts/host-arm-ganesha-seaweedfs.sh`. Both use the same filer and
  volume endpoints and the same 4 GiB volume geometry; the pod's
  Ganesha CPU/memory limits are removed so the host arm is not compared
  against a throttled pod.
- **NFS is a NodePort.** The NFS Service works on a Kind cluster with no
  MetalLB and needs no cloud provider. The node port is fixed at `32049`
  so mount commands stay stable; change it in `40-ganesha-fuse.yaml` if
  it collides with something else.
- **Host arm ordering.** The host script mounts the weed FUSE before it
  starts the host Ganesha (R10); starting Ganesha against the bare
  directory would keep a dirfd and silently miss the mount.
- **Readiness is "serving".** The probe requires both the FUSE mount and
  a TCP accept on 2049, so the Service never reports a pod Ready while
  Ganesha is still initialising.
- **One container for mount + NFS.** A two-container layout with mount
  propagation never delivered the submount on Kind; see
  `../../GANESHA-FUSE-POD.md`.
- **Storage** uses the cluster's default StorageClass (`standard` here,
  backed by local-path). The files live on the node's disk, so they
  survive pod restarts but not node/VM deletion.
- **Vacuum** is disabled at runtime after deployment, for the same reason
  as in the benchmark arm (R11): a sweep rewrites whole volumes and
  interrupts in-flight chunk uploads.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pod `Pending` / PVC unbound | a default StorageClass must exist: `kubectl get sc` |
| `ErrImagePull` / `ImagePullBackOff` | run `up` again; it builds and imports the images |
| `mount.nfs: Connection timed out` | `kubectl get svc seaweedfs-ganesha-fuse`; verify the node IP and port 32049 |
| `Permission denied` creating a file | write under `data/`, not at the export root |
| FUSE mount missing in the pod | `kubectl logs deploy/seaweedfs-ganesha-fuse`, then `cat /var/log/weed-mount.log` in the pod |
| Ganesha errors | `cat /var/log/ganesha/ganesha.log` in the pod |
| Pod `Pending` with hostPort | another process on the node owns 9333/8888/8080 (or 19333/18888/18080); free it or change the hostPorts and matching ports |
| Host arm Ganesha fails | `cat /tmp/ganesha-host-arm.log`; confirm the host FUSE mount is live first (R10) |
| Host arm sees stale/empty data | Ganesha started before the FUSE mount; run `host-arm-ganesha-seaweedfs.sh down` then `up` |

## Tear down

```bash
bash seaweedfs-lab/scripts/host-arm-ganesha-seaweedfs.sh down
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh down
```

The host arm is stopped first (NFS mount, host Ganesha, host FUSE), then
the namespace and its PVCs are deleted. Namespace cleanup can finish
asynchronously after the command returns.
