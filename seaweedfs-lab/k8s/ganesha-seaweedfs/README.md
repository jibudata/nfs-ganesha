# `ganesha-seaweedfs`: a self-contained Ganesha + SeaweedFS test stack

A local-Kubernetes test environment with the complete data path inside the
cluster, in its own namespace. One command creates it, one deletes it.

```text
NFS client (host or pod)
  -> NodePort 32049 (host) / ClusterIP 2049 (in-cluster)
  -> Ganesha container
  -> weed FUSE mount          (same container, same mount namespace)
  -> seaweedfs-filer Service
  -> seaweedfs-volume         (registers its pod IP with the master)
  -> seaweedfs-master
```

This is deliberately **not** the benchmark arm in `seaweedfs-lab/k8s/`.
The benchmark arm runs the FUSE gateway on the host and therefore needs
fixed MetalLB addresses for the master, volume server and filer, plus
fixed-CPU accounting for the measurements. This stack puts every client
inside the cluster (or behind a NodePort), uses ClusterIP Services and
pod-IP registration, and is meant for functional testing, debugging and
demonstrations.

## What runs

| Object | Kind | Notes |
|---|---|---|
| `seaweedfs-master` | Deployment + PVC + ClusterIP | metadata, 9333/19333 |
| `seaweedfs-volume` | StatefulSet + PVC + ClusterIP | data, 8080/18080, 20 GiB PVC |
| `seaweedfs-filer` | Deployment + PVC + ClusterIP | directory tree, 8888/18888 |
| `seaweedfs-ganesha-fuse` | Deployment + ConfigMap + NodePort | FUSE mount + NFSv4.1 in one container |
| `seaweedfs-ganesha-fuse` Service | NodePort | `2049` -> node port `32049` |

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

## Endpoints

```text
Host NFS:       <node InternalIP>:/seaweedfs     port 32049
In-cluster NFS: seaweedfs-ganesha-fuse.ganesha-seaweedfs.svc.cluster.local:/seaweedfs
                port 2049
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

- **No fixed addresses.** In the benchmark arm the FUSE client is on the
  host, so the volume server has to register an address the host can
  reach (R19/R20). Here the FUSE client is the Ganesha pod, pod IPs are
  routable in-cluster, and the volume server keeps its detected pod IP.
- **NodePort, not LoadBalancer.** The NFS Service works on a Kind cluster
  with no MetalLB and needs no cloud provider. The node port is fixed at
  `32049` so mount commands stay stable; change it in
  `40-ganesha-fuse.yaml` if it collides with something else.
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

## Tear down

```bash
bash seaweedfs-lab/scripts/k8s-ganesha-seaweedfs.sh down
```

The test mount is unmounted first; then the namespace and its PVCs are
deleted. Namespace cleanup can finish asynchronously after the command
returns.
