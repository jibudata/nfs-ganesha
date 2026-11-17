#!/bin/bash
# =====================================================================
# k8s-build-image.sh
#
# Get the SeaweedFS image into the node's containerd, in the namespace
# kubelet actually looks in.
#
#   usage: bash k8s-build-image.sh [image:tag]
#
# Why not "docker pull"?  Because the image must carry the HOST's own
# binary: the whole point of the containerised arms is that the storage
# engine is the same build everywhere, so that the only variable between
# the arms is the packaging.  A registry image would quietly change the
# version and make every number meaningless.
#
# Why not "ctr images import" with the default namespace?  Because kubelet
# looks in the containerd namespace "k8s.io", and an image imported into
# "default" is invisible to kubelet - the pod comes up with ErrImagePull
# and the reason is nowhere in the manifest.
#
# WHERE the containerd lives depends on the cluster:
#
#   * a KIND cluster runs its node as a Docker container, so the
#     containerd is inside that container.  KIND names the node container
#     exactly after the node ("kagent-control-plane"), which is what makes
#     the import possible with plain docker.
#   * a real k3s node has its containerd on the host, reachable through
#     "k3s ctr".
#
# Both paths are implemented; the first one that fits the cluster wins.
#
# Nothing is deleted at the end: the desktop's delete guard turns "rm"
# in a script into an interactive trash call that would hang.
# =====================================================================
set -euo pipefail

# The --fio variant builds the image for the pod that mounts FUSE and
# writes with fio: it carries the Ubuntu 24.04 fio package, which is the
# same upstream version (3.36) as the host's local build.  The package is
# used instead of the host's binary because the host's build links ~70
# shared libraries to enable back ends (gluster, ceph, rbd, nbd) that
# this benchmark never touches.  build-image.sh checks the version.
# See docker/Dockerfile-fio.
IMAGE=${1:-seaweedfs-lab:4.54}
VARIANT=${2:-}
NS=${K8S_CTR_NAMESPACE:-k8s.io}
HERE=$(cd "$(dirname "$0")" && pwd)

# kubectl and k3s are not always on the PATH of a non-login ssh session.
KUBECTL=${KUBECTL:-kubectl}
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

K3S_BIN=${K3S_BIN:-k3s}
if ! command -v "$K3S_BIN" >/dev/null 2>&1; then
  for c in /usr/local/bin/k3s /usr/bin/k3s; do
    if [ -x "$c" ]; then K3S_BIN=$c; break; fi
  done
fi

echo "=== build $IMAGE (from the host's own binary) ==="
bash "$HERE/../docker/build-image.sh" "$IMAGE" $VARIANT

NODE=$("$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "=== node: ${NODE:-unknown} ==="

if [ -n "$NODE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NODE"; then
  echo "--- the node is a Docker container ($NODE); importing into it"
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n "$NS" images import -
  echo "--- verify"
  docker exec "$NODE" ctr -n "$NS" images ls -q | grep -qE "(^|/)$IMAGE$" || {
    echo "ERROR: $IMAGE is not in containerd's $NS namespace" >&2
    exit 1
  }
  docker exec "$NODE" ctr -n "$NS" images ls | grep -F "$IMAGE" | sed 's/^/  /'
elif command -v "$K3S_BIN" >/dev/null 2>&1; then
  echo "--- a k3s node; importing through k3s ctr"
  docker save "$IMAGE" | sudo "$K3S_BIN" ctr --namespace "$NS" images import -
  sudo "$K3S_BIN" ctr --namespace "$NS" images ls -q | grep -qE "(^|/)$IMAGE$" || {
    echo "ERROR: $IMAGE is not in containerd's $NS namespace" >&2
    exit 1
  }
  sudo "$K3S_BIN" ctr --namespace "$NS" images ls | grep -F "$IMAGE" | sed 's/^/  /'
else
  echo "ERROR: neither a Docker node container nor a k3s binary was found." >&2
  echo "       The image cannot be placed into the node's containerd." >&2
  exit 1
fi

echo "  ok     the node can run $IMAGE"
echo "build done"
