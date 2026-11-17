#!/bin/bash
# =====================================================================
# k8s-deploy.sh - deploy the Kubernetes arm of the comparison and prove
# that it is usable from the host.
#
#   usage: bash k8s-deploy.sh [up|status|down]
#
# "up" does, in order:
#   1. preflight: kubectl, the node's containerd, the MetalLB pool
#   2. apply the manifests in k8s/
#   3. wait for the workloads to become Ready
#   4. wait for the LoadBalancer addresses to be assigned, and CHECK that
#      they are the addresses the manifests asked for
#   5. from the HOST: open an HTTP request against each address, and
#      open a TCP connection against each gRPC address
#   6. check that the master registered the volume server under the
#      LoadBalancer address - this is the load-bearing check, because
#      that address is the one the host's FUSE mount will use to fetch
#      chunks (weed/filer/reader_at.go:123)
#   7. switch the automatic vacuum sweep off at runtime
#
# Read-only with respect to the other two arms: nothing here touches the
# bare-metal clusters or the Docker stack.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

LAB_ROOT=${LAB_ROOT:-/home/ys1000/seaweedfs}
K8S_DIR=${K8S_DIR:-$LAB_ROOT/k8s}
NS=${K8S_NS:-seaweedfs}
SW_BIN=${SW_BIN:-/usr/local/bin/weed}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

# kubectl is not always on the PATH of a non-login ssh session: on the
# lab host it lives in ~/.local/bin, which the profile adds but a plain
# "ssh host 'cmd'" does not read.  Look for it instead of failing.
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi

# The same goes for k3s: it is in /usr/local/bin, which is on the PATH
# of a login shell but not necessarily of a plain ssh command.
K3S_BIN=${K3S_BIN:-k3s}
if ! command -v "$K3S_BIN" >/dev/null 2>&1; then
  for c in /usr/local/bin/k3s /usr/bin/k3s; do
    if [ -x "$c" ]; then K3S_BIN=$c; break; fi
  done
fi

MASTER_IP=${MASTER_IP:-172.18.255.50}
VOLUME_IP=${VOLUME_IP:-172.18.255.51}
FILER_IP=${FILER_IP:-172.18.255.52}
MASTER_HTTP=${MASTER_HTTP:-19340}
MASTER_GRPC=${MASTER_GRPC:-29340}
VOLUME_HTTP=${VOLUME_HTTP:-19342}
VOLUME_GRPC=${VOLUME_GRPC:-29342}
FILER_HTTP=${FILER_HTTP:-19344}
FILER_GRPC=${FILER_GRPC:-29344}

ACTION=${1:-up}
FAIL=0

say() { echo "$*"; }
ok()  { printf "  %-46s OK\n" "$1"; }
bad() { printf "  %-46s *** FAILED: %s\n" "$1" "$2"; FAIL=1; }

# --- helpers --------------------------------------------------------------

# Does a TCP port accept a connection from here?
# "curl can connect" is not the same thing as "the service answers": a
# proxy can accept and then reset.  So the HTTP check sends a real
# request and looks at the status code.
http_code() { # <url>
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null
}

tcp_open() { # <host> <port>
  (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null || return 1
  exec 3<&- 3>&- 2>/dev/null
  return 0
}

lb_ip() { # <service>
  "$KUBECTL" -n "$NS" get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

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

svc_has_ip() { [ -n "$(lb_ip "$1")" ]; }

# --- datadir --------------------------------------------------------------

# The size of the volume server's .dat files, in bytes.
#
# It is measured from INSIDE the volume pod on purpose.  The local-path
# provisioner makes the PersistentVolume a hostPath on the NODE, and the
# node is not necessarily the machine this script runs on: a KIND cluster
# runs its node as a Docker container, and then that path does not exist
# on the host.  A landing check that looks for it finds nothing and
# concludes "the write was lost" - a false negative, and the exact
# failure this lab exists to avoid.  The pod sees the data wherever the
# node lives.
do_datsize() {
  bash "$HERE/k8s-volume-datsize.sh"
}

# --- the node's containerd ------------------------------------------------

# Is <image> in the containerd that kubelet looks at?
#
# Where that containerd lives depends on the cluster: a KIND node runs it
# inside the node's Docker container, a real k3s node on the host.
node_name() {
  "$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

image_present() { # <image>
  local img=$1 node
  node=$(node_name)
  if [ -n "$node" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$node"; then
    # containerd normalises the name: "seaweedfs-lab:4.54" is stored as
    # "docker.io/library/seaweedfs-lab:4.54".  Match the tail.
    docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  else
    sudo "$K3S_BIN" ctr --namespace k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  fi
}

# --- status ---------------------------------------------------------------

do_status() {
  say "=== the Kubernetes arm ==="
  "$KUBECTL" -n "$NS" get pods -o wide 2>/dev/null || say "  (namespace $NS is not there)"
  say ""
  for s in seaweedfs-master seaweedfs-volume seaweedfs-filer; do
    printf "  %-18s loadBalancer IP: %s\n" "$s" "$(lb_ip "$s")"
  done
  say ""
  say "  master  http $MASTER_IP:$MASTER_HTTP  -> $(http_code "http://$MASTER_IP:$MASTER_HTTP/healthz")"
  say "  volume  http $VOLUME_IP:$VOLUME_HTTP  -> $(http_code "http://$VOLUME_IP:$VOLUME_HTTP/healthz")"
  say "  filer   http $FILER_IP:$FILER_HTTP    -> $(http_code "http://$FILER_IP:$FILER_HTTP/healthz")"
}

# --- up -------------------------------------------------------------------

do_up() {
  say "=== preflight ==="
  command -v "$KUBECTL" >/dev/null 2>&1 || { say "ERROR: kubectl is not there"; exit 2; }
  [ -x "$SW_BIN" ] || { say "ERROR: $SW_BIN is not there"; exit 2; }
  [ -d "$K8S_DIR" ] || { say "ERROR: $K8S_DIR is not there"; exit 2; }
  say "  node: $(node_name)"

  local pool
  pool=$("$KUBECTL" get ipaddresspools.metallb.io -A -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null)
  say "  MetalLB pools: $pool"
  case "$pool" in
    *172.18.255.*) ok "the MetalLB pool covers 172.18.255.x" ;;
    *) bad "the MetalLB pool" "it does not cover 172.18.255.x" ;;
  esac

  # The image has to be in the containerd namespace kubelet looks in.
  if image_present seaweedfs-lab:4.54; then
    ok "seaweedfs-lab:4.54 is in containerd"
  else
    say "  the image is not in the node's containerd; building and importing it"
    bash "$HERE/k8s-build-image.sh" || { say "ERROR: the image build failed"; exit 1; }
    if image_present seaweedfs-lab:4.54; then
      ok "seaweedfs-lab:4.54 is in containerd"
    else
      bad "seaweedfs-lab:4.54" "it is still not in the node's containerd"
    fi
  fi

  say ""
  say "=== apply ==="
  "$KUBECTL" apply -f "$K8S_DIR" 2>&1 | sed 's/^/  /'

  say ""
  say "=== wait for the workloads ==="
  if wait_for 180 "$KUBECTL" -n "$NS" wait --for=condition=Ready pod -l app=seaweedfs-master --timeout=10s; then
    ok "the master is Ready"
  else bad "the master" "not Ready"; fi
  if wait_for 180 "$KUBECTL" -n "$NS" wait --for=condition=Ready pod -l app=seaweedfs-volume --timeout=10s; then
    ok "the volume server is Ready"
  else bad "the volume server" "not Ready"; fi
  if wait_for 180 "$KUBECTL" -n "$NS" wait --for=condition=Ready pod -l app=seaweedfs-filer --timeout=10s; then
    ok "the filer is Ready"
  else bad "the filer" "not Ready"; fi

  say ""
  say "=== wait for the LoadBalancer addresses ==="
  # The address has to be the one the manifests asked for.  A pool that
  # hands out a different address would leave the pods advertising an
  # address nobody routes to, and the host's FUSE mount would fail at
  # the first chunk fetch - a failure that looks like a slow disk.
  for pair in "seaweedfs-master $MASTER_IP" \
              "seaweedfs-volume $VOLUME_IP" \
              "seaweedfs-filer $FILER_IP"; do
    set -- $pair
    local svc=$1 want=$2 got
    if wait_for 120 svc_has_ip "$svc"; then
      got=$(lb_ip "$svc")
      if [ "$got" = "$want" ]; then
        ok "$svc has the address $got"
      else
        bad "$svc" "it got $got, the manifests asked for $want"
      fi
    else
      bad "$svc" "no LoadBalancer address after 120 s"
    fi
  done

  say ""
  say "=== from the HOST: the addresses have to answer ==="
  local code
  code=$(http_code "http://$MASTER_IP:$MASTER_HTTP/healthz")
  case "$code" in 2*|3*) ok "master  http://$MASTER_IP:$MASTER_HTTP/healthz -> $code" ;;
                *) bad "master http" "HTTP $code" ;; esac
  code=$(http_code "http://$VOLUME_IP:$VOLUME_HTTP/healthz")
  case "$code" in 2*|3*) ok "volume  http://$VOLUME_IP:$VOLUME_HTTP/healthz -> $code" ;;
                *) bad "volume http" "HTTP $code" ;; esac
  code=$(http_code "http://$FILER_IP:$FILER_HTTP/healthz")
  case "$code" in 2*|3*) ok "filer   http://$FILER_IP:$FILER_HTTP/healthz -> $code" ;;
                *) bad "filer http" "HTTP $code" ;; esac

  if tcp_open "$MASTER_IP" "$MASTER_GRPC"; then ok "master  grpc $MASTER_IP:$MASTER_GRPC accepts"; else bad "master grpc" "refused"; fi
  if tcp_open "$VOLUME_IP" "$VOLUME_GRPC"; then ok "volume  grpc $VOLUME_IP:$VOLUME_GRPC accepts"; else bad "volume grpc" "refused"; fi
  if tcp_open "$FILER_IP" "$FILER_GRPC"; then ok "filer   grpc $FILER_IP:$FILER_GRPC accepts"; else bad "filer grpc" "refused"; fi

  say ""
  say "=== the master has to know the volume under the LoadBalancer address ==="
  # This is the check the whole design rests on.  The host's FUSE mount
  # fetches a chunk from the address the master recorded for the volume
  # server (weed/filer/reader_at.go:123 -> weed/topology/topology_info.go
  # -> dn.Url() = <the volume's -ip>:<port>).  If the master recorded the
  # pod IP instead, the mount would reach for an address the host cannot
  # route, and the arm would measure something else entirely.
  local topo
  topo=$(curl -s --max-time 10 "http://$MASTER_IP:$MASTER_HTTP/" 2>/dev/null)
  if printf '%s' "$topo" | grep -q "$VOLUME_IP"; then
    ok "the master registered the volume at $VOLUME_IP"
  else
    bad "the master's topology" "it does not mention $VOLUME_IP"
  fi

  # The master does NOT keep a filer registry - there is no filer list in
  # the master's topology, because the filer is a client of the master,
  # not a member of its topology.  So "the filer is in the master's
  # topology" was never going to be true, and the check that looked for
  # it could only ever fail.
  #
  # What the filer DOES need is the master: it allocates every chunk
  # through it.  So the check is that the master answers FROM INSIDE the
  # filer pod.  The probe is the same weed binary the pod already runs,
  # so no extra tooling is needed in the image.
  local from_filer
  from_filer=$(printf 'cluster.status\nexit\n' \
    | timeout 30 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-filer -- \
        /usr/local/bin/weed shell -master="$MASTER_IP:$MASTER_HTTP" 2>&1)
  # The status is a count overview, not an address list, so the marker is
  # the section header: what matters here is that the master ANSWERED
  # from inside the filer pod.
  if printf '%s' "$from_filer" | grep -q "topology:"; then
    ok "the filer reaches the master, and the master sees the topology"
  else
    bad "the filer's route to the master" "it did not get a cluster status"
  fi

  say ""
  say "=== switch the automatic vacuum sweep off ==="
  # -vacuumIntervalSeconds=86400 spaces the sweeps out, but the sweep
  # loop runs its body BEFORE the first sleep, so a fresh master sweeps
  # once immediately.  The runtime switch is what actually stops it.
  # See LAB-CONVENTIONS.md R11.
  if printf 'lock\nvolume.vacuum.disable\nunlock\nexit\n' \
       | timeout 30 "$SW_BIN" shell -master="$MASTER_IP:$MASTER_HTTP" >/tmp/k8s-vacuum-disable.log 2>&1; then
    ok "the automatic vacuum sweep is disabled"
  else
    bad "the vacuum switch" "the shell command failed; see /tmp/k8s-vacuum-disable.log"
  fi

  say ""
  do_status
  say ""
  if [ "$FAIL" = "0" ]; then
    say "K8S ARM DEPLOYED"
  else
    say "K8S ARM DEPLOYED WITH FAILURES"
  fi
  return "$FAIL"
}

# --- down -----------------------------------------------------------------

do_down() {
  say "=== deleting the Kubernetes arm ==="
  "$KUBECTL" delete -f "$K8S_DIR" --ignore-not-found 2>&1 | sed 's/^/  /'
  "$KUBECTL" delete namespace "$NS" --ignore-not-found 2>&1 | sed 's/^/  /'
  say "done"
}

case "$ACTION" in
  up)       do_up ;;
  status)   do_status ;;
  datsize)  do_datsize ;;
  down)     do_down ;;
  *) echo "usage: $0 up|status|datsize|down" >&2; exit 2 ;;
esac
