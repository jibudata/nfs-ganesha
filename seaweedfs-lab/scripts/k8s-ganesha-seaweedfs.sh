#!/bin/bash
# =====================================================================
# k8s-ganesha-seaweedfs.sh - a self-contained Ganesha + SeaweedFS stack
# for local Kubernetes testing, in namespace "ganesha-seaweedfs".
#
#   usage: bash k8s-ganesha-seaweedfs.sh up|status|test|down
#
# Layout: everything is a pod.
#
#   NFS client -> NodePort 32049 -> Ganesha (one container)
#              -> weed FUSE mount  -> filer -> volume -> master
#
# This is deliberately NOT the benchmark arm.  The benchmark arm keeps
# the FUSE gateway on the host, so its volume server has to register a
# fixed MetalLB address the host can reach (LAB-CONVENTIONS R19/R20).
# Here the FUSE client is a pod, pod IPs are routable in-cluster, and the
# only external entry point is the NFS NodePort.  No MetalLB, no fixed
# LoadBalancer address, one namespace to delete.
#
# "test" mounts the export on the HOST through the node IP and the
# NodePort, writes random data, reads it back through NFS, and proves the
# bytes reached the volume server's .dat files (R4: a write is not done
# until the bytes have landed).
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAB_ROOT=$(cd "$HERE/.." && pwd)
K8S_DIR=${K8S_DIR:-$LAB_ROOT/k8s/ganesha-seaweedfs}
NS=${NS:-ganesha-seaweedfs}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

SW_IMAGE=${SW_IMAGE:-seaweedfs-lab:4.54}
GANESHA_IMAGE=${GANESHA_IMAGE:-seaweedfs-lab:ganesha-v15.9}
NFS_MNT=${NFS_MNT:-/mnt/ganesha-seaweedfs-test}
NFS_SIZE_MB=${NFS_SIZE_MB:-8}

ACTION=${1:-up}
FAIL=0

say() { echo "$*"; }
ok()  { printf "  %-52s OK\n" "$1"; }
bad() { printf "  %-52s *** FAILED: %s\n" "$1" "$2"; FAIL=1; }

# kubectl is not always on the PATH of a non-login ssh session.
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi

# --- cluster helpers ------------------------------------------------------

node_name() { "$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
node_ip()   { "$KUBECTL" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null; }

nfs_node_port() {
  "$KUBECTL" -n "$NS" get svc seaweedfs-ganesha-fuse \
    -o jsonpath='{.spec.ports[?(@.name=="nfs")].nodePort}' 2>/dev/null
}

pod_ready() { # <label-selector>
  [ "$("$KUBECTL" -n "$NS" get pods -l "$1" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

ns_active() { [ "$("$KUBECTL" get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Active" ]; }

wait_for() { # <seconds> <command...>
  local secs=$1; shift
  local i=0
  while [ "$i" -lt "$secs" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
    i=$((i + 2))
  done
  return 1
}

# Is <image> in the containerd kubelet looks in?  A Kind node runs as a
# Docker container; a k3s node has k3s ctr on the host.  Same logic as
# k8s-deploy.sh.
image_present() { # <image>
  local img=$1 node
  node=$(node_name)
  [ -n "$node" ] || return 1
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$node"; then
    docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  elif command -v k3s >/dev/null 2>&1; then
    sudo k3s ctr --namespace k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  else
    return 1
  fi
}

# Is the path a mount in the kernel's table?  Never stat() it: a wedged
# NFS mount blocks in D state (R2).
is_mounted() {
  awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

fstype_of() {
  awk -v p="$1" '$2 == p { print $3 }' /proc/mounts 2>/dev/null
}

# Total size of the volume server's .dat files, in bytes, measured from
# INSIDE the volume pod: on Kind the node is a container, so the PVC's
# host path does not exist on this machine (R23).
datsize() {
  "$KUBECTL" -n "$NS" exec statefulset/seaweedfs-volume -- sh -c \
    "find /data/vol -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END {print s+0}'" \
    2>/dev/null
}

# --- preflight ------------------------------------------------------------

do_preflight() {
  say "=== preflight ==="
  command -v "$KUBECTL" >/dev/null 2>&1 || { say "ERROR: kubectl is not there"; exit 2; }
  [ -d "$K8S_DIR" ] || { say "ERROR: $K8S_DIR is not there"; exit 2; }
  say "  context: $("$KUBECTL" config current-context 2>/dev/null)"
  say "  node:    $(node_name)"

  if image_present "$SW_IMAGE"; then
    ok "$SW_IMAGE is in the node's containerd"
  else
    say "  $SW_IMAGE is not in the node's containerd; building it"
    bash "$HERE/k8s-build-image.sh" "$SW_IMAGE" || {
      say "ERROR: the SeaweedFS image build failed"; exit 1; }
    image_present "$SW_IMAGE" || { say "ERROR: $SW_IMAGE is still not loaded"; exit 1; }
    ok "$SW_IMAGE is in the node's containerd"
  fi

  if image_present "$GANESHA_IMAGE"; then
    ok "$GANESHA_IMAGE is in the node's containerd"
  else
    say "  $GANESHA_IMAGE is not in the node's containerd; building it from this checkout"
    say "  (a full Ganesha build takes a while; it is built once per source change)"
    WEED_IMAGE="$SW_IMAGE" bash "$HERE/k8s-build-ganesha-image.sh" "$GANESHA_IMAGE" || {
      say "ERROR: the Ganesha image build failed"; exit 1; }
    image_present "$GANESHA_IMAGE" || { say "ERROR: $GANESHA_IMAGE is still not loaded"; exit 1; }
    ok "$GANESHA_IMAGE is in the node's containerd"
  fi
}

# --- up -------------------------------------------------------------------

do_up() {
  do_preflight

  say ""
  say "=== namespace ==="
  "$KUBECTL" apply -f "$K8S_DIR/00-namespace.yaml" 2>&1 | sed 's/^/  /'
  if wait_for 30 ns_active; then ok "namespace $NS is Active"; else bad "namespace $NS" "not Active"; fi

  say ""
  say "=== SeaweedFS storage plane ==="
  "$KUBECTL" apply -f "$K8S_DIR/10-master.yaml" 2>&1 | sed 's/^/  /'
  if wait_for 180 "$KUBECTL" -n "$NS" rollout status deployment/seaweedfs-master --timeout=10s; then
    ok "the master is Ready"
  else bad "the master" "not Ready"; fi

  "$KUBECTL" apply -f "$K8S_DIR/20-volume.yaml" 2>&1 | sed 's/^/  /'
  if wait_for 300 "$KUBECTL" -n "$NS" rollout status statefulset/seaweedfs-volume --timeout=10s; then
    ok "the volume server is Ready"
  else bad "the volume server" "not Ready"; fi

  "$KUBECTL" apply -f "$K8S_DIR/30-filer.yaml" 2>&1 | sed 's/^/  /'
  if wait_for 180 "$KUBECTL" -n "$NS" rollout status deployment/seaweedfs-filer --timeout=10s; then
    ok "the filer is Ready"
  else bad "the filer" "not Ready"; fi

  say ""
  say "=== Ganesha + FUSE ==="
  "$KUBECTL" apply -f "$K8S_DIR/40-ganesha-fuse.yaml" 2>&1 | sed 's/^/  /'
  if wait_for 300 "$KUBECTL" -n "$NS" rollout status deployment/seaweedfs-ganesha-fuse --timeout=10s; then
    ok "Ganesha is serving the FUSE export"
  else bad "Ganesha/FUSE" "not Ready"; fi

  say ""
  say "=== switch the automatic vacuum sweep off ==="
  # -vacuumIntervalSeconds spaces the sweeps out, but the sweep loop runs
  # its body before the first sleep, so a fresh master sweeps once at
  # startup.  The runtime switch is what actually stops it (R11).
  if printf 'lock\nvolume.vacuum.disable\nunlock\nexit\n' \
       | timeout 30 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-master -- \
           /usr/local/bin/weed shell -master=127.0.0.1:9333 >/dev/null 2>&1; then
    ok "the automatic vacuum sweep is disabled"
  else
    say "  WARN: could not disable the vacuum sweep; run this by hand:"
    say "        kubectl -n $NS exec -i deploy/seaweedfs-master -- weed shell -master=127.0.0.1:9333"
    say "        lock / volume.vacuum.disable / unlock"
  fi

  say ""
  do_status
  say ""
  if [ "$FAIL" = "0" ]; then
    say "GANESHA-SEAWEEDFS STACK READY"
  else
    say "GANESHA-SEAWEEDFS STACK DEPLOYED WITH FAILURES"
  fi
  return "$FAIL"
}

# --- status ---------------------------------------------------------------

do_status() {
  say "=== ganesha-seaweedfs ==="
  "$KUBECTL" -n "$NS" get pods,svc,pvc -o wide 2>/dev/null || {
    say "  (namespace $NS is not there)"; return 1; }

  local nip nport
  nip=$(node_ip)
  nport=$(nfs_node_port)

  say ""
  say "  NFS from the host:  $nip:/seaweedfs   (port ${nport:-<pending>})"
  say "  NFS in-cluster:     seaweedfs-ganesha-fuse.$NS.svc.cluster.local:/seaweedfs  (port 2049)"

  say ""
  if pod_ready app=seaweedfs-master; then
    local status
    status=$("$KUBECTL" get --raw \
      "/api/v1/namespaces/$NS/services/http:seaweedfs-master:9333/proxy/cluster/status" 2>/dev/null)
    if [ -n "$status" ]; then
      ok "the master answers: $(printf '%s' "$status" | head -c 160)"
    else
      bad "the master's cluster status" "the API server proxy returned nothing"
    fi
  else
    bad "the master" "not Ready"
  fi

  if pod_ready app=seaweedfs-ganesha-fuse; then
    if "$KUBECTL" -n "$NS" exec deploy/seaweedfs-ganesha-fuse -- \
         awk '$2 == "/mnt/seaweedfs" && $3 == "fuse.seaweedfs" { f=1 } END { exit !f }' /proc/mounts; then
      ok "the FUSE mount is present in the Ganesha container"
    else
      bad "the FUSE mount" "not in the container's /proc/mounts"
    fi
    if "$KUBECTL" -n "$NS" exec deploy/seaweedfs-ganesha-fuse -- \
         timeout 2 bash -c '</dev/tcp/127.0.0.1/2049' 2>/dev/null; then
      ok "Ganesha listens on 2049 inside the container"
    else
      bad "Ganesha's NFS port" "nothing accepts on 2049"
    fi
  else
    bad "the Ganesha/FUSE pod" "not Ready"
  fi
}

# --- test -----------------------------------------------------------------

do_test() {
  say "=== functional test: host NFS client through the NodePort ==="
  local nip nport before after delta i sum fsize
  nip=$(node_ip)
  nport=$(nfs_node_port)
  if [ -z "$nip" ] || [ -z "$nport" ]; then
    say "ERROR: the node IP or the NFS NodePort is not assigned yet"; return 1
  fi
  pod_ready app=seaweedfs-ganesha-fuse || {
    say "ERROR: the Ganesha/FUSE pod is not Ready; run 'up' first"; return 1; }

  # A previous test mount would shadow this one; bounded and lazy (R3).
  if is_mounted "$NFS_MNT"; then
    say "  unmounting a previous test mount at $NFS_MNT"
    timeout 15 sudo umount -l "$NFS_MNT" >/dev/null 2>&1 || true
  fi
  sudo mkdir -p "$NFS_MNT"

  before=$(datsize)
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  say "  volume .dat bytes before: $before"

  say "  mounting $nip:/seaweedfs on $NFS_MNT (port $nport)"
  if ! sudo mount -t nfs -o vers=4.1,proto=tcp,port="$nport",soft,timeo=50,retrans=2 \
        "$nip:/seaweedfs" "$NFS_MNT"; then
    bad "the NFS mount" "mount.nfs failed; check that NodePort $nport is reachable"
    return 1
  fi
  local fstype
  fstype=$(fstype_of "$NFS_MNT")
  case "$fstype" in
    nfs|nfs4) ok "mounted, fstype=$fstype" ;;
    *)        bad "the test mount" "fstype is '${fstype:-unknown}', not nfs" ;;
  esac

  # The export is Root_Squash and the FUSE root is not writable; the
  # entrypoint prepared /data as mode 0777 (EXPORT_SUBDIR=data).
  if ! sudo mkdir -p "$NFS_MNT/data"; then
    bad "the export's data directory" "cannot create it through NFS"
    timeout 15 sudo umount -l "$NFS_MNT" >/dev/null 2>&1 || true
    return 1
  fi

  local fname="smoke-$(date +%Y%m%d-%H%M%S)-$$.bin"
  say "  writing ${NFS_SIZE_MB} MiB of random data to /data/$fname"
  if ! sudo dd if=/dev/urandom of="$NFS_MNT/data/$fname" bs=1M count="$NFS_SIZE_MB" status=none; then
    bad "the NFS write" "dd failed"
  fi
  sudo sync
  sum=$(sudo sha256sum "$NFS_MNT/data/$fname" | awk '{print $1}')
  fsize=$(sudo stat -c %s "$NFS_MNT/data/$fname" 2>/dev/null)
  if [ "$fsize" = "$((NFS_SIZE_MB * 1024 * 1024))" ]; then
    ok "read back $fsize bytes through NFS (sha256 ${sum:0:16}...)"
  else
    bad "the read-back size" "got '${fsize:-?}', expected $((NFS_SIZE_MB * 1024 * 1024))"
  fi

  # Unmount before measuring the backend: this also makes sure the test
  # does not leave a host NFS mount behind if the next check fails.
  timeout 15 sudo umount -l "$NFS_MNT" >/dev/null 2>&1 || true

  say "  waiting for the bytes to land in the volume server"
  after=$before
  for i in $(seq 1 15); do
    after=$(datsize)
    case "$after" in ''|*[!0-9]*) after=0 ;; esac
    delta=$((after - before))
    [ "$delta" -gt 0 ] && break
    sleep 2
  done
  if [ "$delta" -gt 0 ]; then
    ok "volume .dat grew by $delta bytes"
    if [ "$delta" -lt "$((NFS_SIZE_MB * 1024 * 1024))" ]; then
      say "  note: less than the ${NFS_SIZE_MB} MiB written; the rest may still be in flight"
    fi
  else
    bad "the landing check" "the .dat files did not grow; the write did not reach the volume server"
  fi

  # Metadata check, informational: fs.ls through the filer.  The shell
  # output format varies between releases, so a miss is a warning, not a
  # failed test - the .dat growth above is the load-bearing assertion.
  local listing
  listing=$(printf 'fs.ls /data\nexit\n' \
    | timeout 30 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-filer -- \
        /usr/local/bin/weed shell -master=seaweedfs-master:9333 2>&1)
  if printf '%s' "$listing" | grep -q "$fname"; then
    ok "the filer lists /data/$fname"
  else
    say "  note: the filer shell did not list $fname; last lines:"
    printf '%s\n' "$listing" | tail -5 | sed 's/^/    /'
  fi

  say ""
  if [ "$FAIL" = "0" ]; then
    say "NFS -> GANESHA -> FUSE -> FILER -> VOLUME: PASS"
  else
    say "NFS -> GANESHA -> FUSE -> FILER -> VOLUME: FAIL"
  fi
  return "$FAIL"
}

# --- down -----------------------------------------------------------------

do_down() {
  say "=== deleting the ganesha-seaweedfs stack ==="
  if is_mounted "$NFS_MNT"; then
    say "  unmounting $NFS_MNT"
    timeout 15 sudo umount -l "$NFS_MNT" >/dev/null 2>&1 || true
  fi
  "$KUBECTL" delete -f "$K8S_DIR" --ignore-not-found 2>&1 | sed 's/^/  /'
  "$KUBECTL" delete namespace "$NS" --ignore-not-found 2>&1 | sed 's/^/  /'
  say "done (PVC cleanup finishes asynchronously if the namespace is still Terminating)"
}

case "$ACTION" in
  up)     do_up ;;
  status) do_status ;;
  test)   do_test ;;
  down)   do_down ;;
  *) echo "usage: $0 up|status|test|down" >&2; exit 2 ;;
esac
