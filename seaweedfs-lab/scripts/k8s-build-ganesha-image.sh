#!/usr/bin/env bash
# Build Ganesha from this checkout and make the image available to the K8s node.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${1:-seaweedfs-lab:ganesha-v15.9}
NS=${K8S_CTR_NAMESPACE:-k8s.io}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null
# nTIRPC and its nested prometheus headers are required by the build.
git submodule update --init --recursive --depth 1 src/libntirpc
printf 'Building Ganesha image %s from %s\n' "$IMAGE" "$(git rev-parse HEAD)"
docker build -f seaweedfs-lab/docker/Dockerfile-ganesha -t "$IMAGE" .
docker run --rm --entrypoint ganesha.nfsd "$IMAGE" -v

NODE=$("$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}')
if [ -n "$NODE" ] && docker ps --format '{{.Names}}' | grep -qx "$NODE"; then
  echo "Importing image into KIND node $NODE"
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n "$NS" images import -
  docker exec "$NODE" ctr -n "$NS" images ls | grep -F "$IMAGE"
elif command -v k3s >/dev/null 2>&1; then
  echo "Importing image into k3s containerd"
  docker save "$IMAGE" | sudo k3s ctr --namespace "$NS" images import -
  sudo k3s ctr --namespace "$NS" images ls | grep -F "$IMAGE"
else
  echo "ERROR: unable to identify KIND node or k3s containerd; import $IMAGE into the cluster runtime manually" >&2
  exit 1
fi
