#!/bin/bash
# =====================================================================
# host-arm-ganesha-seaweedfs.sh - Ganesha + weed FUSE on the HOST,
# sharing the SeaweedFS backend in namespace ganesha-seaweedfs.
#
#   usage: bash host-arm-ganesha-seaweedfs.sh up|status|down
#
# Host arm data path:
#
#   host fio -> NFS (host Ganesha :2049) -> host weed FUSE
#            -> 172.18.0.2:8888 (filer hostPort)
#            -> 172.18.0.2:8080 (volume hostPort, returned by the filer)
#
# The pod arm (seaweedfs-ganesha-fuse Deployment) uses the same filer and
# volume endpoints, so the backend is identical and only the Ganesha+FUSE
# placement differs.
#
# The FUSE mount is created BEFORE Ganesha starts (R10): a Ganesha that
# resolves the bare directory first keeps a dirfd to it, and later
# writes miss the mount.
#
# This script does not deploy or modify the K8s stack.  Run
# k8s-ganesha-seaweedfs.sh up first.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAB_ROOT=$(cd "$HERE/.." && pwd)
. "$HERE/lib-nfslab.sh"

NS=${K8S_NS:-ganesha-seaweedfs}
NODE_IP=${NODE_IP:-172.18.0.2}
FILER=${FILER:-$NODE_IP:8888}
HOST_MNT=${HOST_MNT:-/home/ys1000/seaweedfs/mnt-k8s}
HOST_CACHE=${HOST_CACHE:-/dev/shm/seaweedfs-host-fuse-cache}
HOST_LOG=${HOST_LOG:-/home/ys1000/seaweedfs/logs/weed-mount-host-arm.log}
NFS_MNT=${NFS_MNT:-/mnt/ganesha-host-arm}
NFS_PORT=${NFS_PORT:-2049}
GANESHA_CONF=${GANESHA_CONF:-$LAB_ROOT/k8s/ganesha-seaweedfs/host-arm/ganesha.conf}
GANESHA_LOG=${GANESHA_LOG:-/tmp/ganesha-host-arm.log}
GANESHA_PID=${GANESHA_PID:-/tmp/ganesha-host-arm.pid}
SW_BIN=${SW_BIN:-/usr/local/bin/weed}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi

ACTION=${1:-up}
FAIL=0
say() { echo "$*"; }
ok()  { printf "  %-56s OK\n" "$1"; }
bad() { printf "  %-56s *** FAILED: %s\n" "$1" "$2"; FAIL=1; }

tcp_open() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null || return 1; exec 3<&-; exec 3>&-; return 0; }

ganesha_pid() {
  [ -s "$GANESHA_PID" ] || return 1
  sudo cat "$GANESHA_PID" 2>/dev/null
}

do_up() {
  say "=== preflight ==="
  command -v "$KUBECTL" >/dev/null 2>&1 || { say "ERROR: kubectl not found"; exit 2; }
  [ -x "$SW_BIN" ] || { say "ERROR: $SW_BIN not found"; exit 2; }
  [ -f "$GANESHA_CONF" ] || { say "ERROR: $GANESHA_CONF not found"; exit 2; }

  local ready
  ready=$("$KUBECTL" -n "$NS" get pods -l app=seaweedfs-ganesha-fuse \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$ready" = "True" ]; then
    ok "the pod arm is Ready"
  else
    bad "the pod arm" "not Ready; run k8s-ganesha-seaweedfs.sh up"
  fi

  if tcp_open "${FILER%:*}" "${FILER##*:}"; then
    ok "the filer hostPort $FILER is reachable"
  else
    bad "the filer hostPort" "$FILER is not reachable"
  fi

  say ""
  say "=== host weed FUSE ==="
  if is_fuse_mounted "$HOST_MNT"; then
    ok "$HOST_MNT is already a fuse.seaweedfs mount"
  else
    mkdir -p "$HOST_MNT" "$HOST_CACHE" "$(dirname "$HOST_LOG")"
    say "  mounting $HOST_MNT from $FILER"
    nohup "$SW_BIN" mount \
      -filer="$FILER" \
      -dir="$HOST_MNT" \
      -volumeName=seaweedfs-ganesha-pod \
      -allowOthers=true \
      -defaultPermissions=true \
      -umask=022 \
      -cacheDir="$HOST_CACHE" \
      -cacheCapacityMB=128 \
      -cacheMetaTtlSec=60 \
      -chunkSizeLimitMB=8 \
      -writeBufferSizeMB=4096 \
      -concurrentWriters=64 \
      -concurrentReaders=64 \
      -metadataFlushSeconds=120 \
      -fuse.maxBackground=128 \
      -fuse.congestionThreshold=0 \
      -df.logical \
      -dlm >> "$HOST_LOG" 2>&1 &
    disown
    local i
    for i in $(seq 1 60); do
      is_fuse_mounted "$HOST_MNT" && break
      sleep 1
    done
    if is_fuse_mounted "$HOST_MNT"; then
      ok "$HOST_MNT is a fuse.seaweedfs mount"
    else
      bad "the host FUSE mount" "not up; see $HOST_LOG"
      tail -20 "$HOST_LOG" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  if [ "$FAIL" != "0" ]; then
    say "ERROR: the host FUSE mount is not ready; refusing to start Ganesha (R10)"
    return "$FAIL"
  fi

  mkdir -p "$HOST_MNT/data"
  # The FUSE server may refuse setattr on a directory that already exists
  # (the same EAGAIN/EPERM the CI workaround hits).  The pod arm creates
  # data/ mode 0777; if the chmod is refused, keep the existing mode.
  chmod 0777 "$HOST_MNT/data" 2>/dev/null || true
  if [ -w "$HOST_MNT/data" ]; then
    ok "the export data directory is $HOST_MNT/data (writable)"
  else
    bad "the export data directory" "$HOST_MNT/data is not writable"
  fi

  say ""
  say "=== host Ganesha ==="
  if tcp_open 127.0.0.1 "$NFS_PORT"; then
    ok "Ganesha is already listening on $NFS_PORT"
  else
    # Start AFTER the FUSE mount is live (R10).
    sudo nohup /usr/bin/ganesha.nfsd -x -F -f "$GANESHA_CONF" \
      -N NIV_EVENT -L "$GANESHA_LOG" -p "$GANESHA_PID" >/dev/null 2>&1 &
    local i
    for i in $(seq 1 30); do
      tcp_open 127.0.0.1 "$NFS_PORT" && break
      sleep 1
    done
    if tcp_open 127.0.0.1 "$NFS_PORT"; then
      ok "Ganesha is listening on $NFS_PORT"
    else
      bad "the host Ganesha" "no listener on $NFS_PORT; see $GANESHA_LOG"
      tail -20 "$GANESHA_LOG" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  say ""
  say "=== host NFS client ==="
  if is_mounted "$NFS_MNT"; then
    ok "$NFS_MNT is already mounted"
  else
    sudo mkdir -p "$NFS_MNT"
    if sudo mount -t nfs \
         -o vers=4.1,proto=tcp,port="$NFS_PORT",rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
         127.0.0.1:/seaweedfs-host "$NFS_MNT"; then
      ok "mounted 127.0.0.1:/seaweedfs-host on $NFS_MNT"
    else
      bad "the host NFS mount" "mount.nfs failed"
    fi
  fi
  awk -v m="$NFS_MNT" '$2 == m {print "  " $0}' /proc/mounts

  say ""
  say "HOST ARM READY"
  say "  NFS:       127.0.0.1:/seaweedfs-host  port $NFS_PORT"
  say "  fio dir:   $NFS_MNT/data"
  say "  filer:     $FILER (hostPort)"
  say "  volume:    ${FILER%:*}:8080 (hostPort, returned by the filer)"
  say ""
  say "Pod arm for comparison:"
  say "  NFS:       $NODE_IP:/seaweedfs port 32049 (Service seaweedfs-ganesha-fuse)"
  say "  fio dir:   /mnt/ganesha-seaweedfs/data"
  return "$FAIL"
}

do_status() {
  say "=== host arm ==="
  if is_fuse_mounted "$HOST_MNT"; then
    ok "$HOST_MNT is a fuse.seaweedfs mount"
  else
    bad "the host FUSE mount" "not present"
  fi
  if tcp_open 127.0.0.1 "$NFS_PORT"; then
    ok "Ganesha listens on $NFS_PORT"
  else
    bad "the host Ganesha" "no listener on $NFS_PORT"
  fi
  if is_mounted "$NFS_MNT"; then
    ok "$NFS_MNT is mounted"
  else
    bad "the host NFS client mount" "not present"
  fi
  echo "  pid: $(ganesha_pid 2>/dev/null || echo none)  log: $GANESHA_LOG"

  say ""
  say "=== K8s backend ==="
  "$KUBECTL" -n "$NS" get pods -o wide 2>/dev/null | sed 's/^/  /'
  printf 'volume.list\nexit\n' | timeout 30 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-master -- \
    /usr/local/bin/weed shell -master=127.0.0.1:9333 2>&1 | head -1 | sed 's/^/  /'
}

do_down() {
  say "=== host arm teardown ==="
  if is_mounted "$NFS_MNT"; then
    say "  unmounting $NFS_MNT"
    lazy_unmount "$NFS_MNT"
  fi

  # Stop Ganesha before detaching the export it holds.
  local p
  p=$(ganesha_pid 2>/dev/null || true)
  if [ -n "$p" ] && sudo kill -0 "$p" 2>/dev/null; then
    say "  stopping host Ganesha (pid $p)"
    sudo kill "$p" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
      sudo kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    sudo kill -9 "$p" 2>/dev/null || true
  fi

  if is_fuse_mounted "$HOST_MNT"; then
    say "  unmounting $HOST_MNT"
    timeout 15 fusermount3 -u "$HOST_MNT" >/dev/null 2>&1 \
      || timeout 15 sudo umount -l "$HOST_MNT" >/dev/null 2>&1 \
      || true
  fi
  say "done"
  say "the K8s stack is untouched; the pod arm is still serving"
}

case "$ACTION" in
  up)     do_up ;;
  status) do_status ;;
  down)   do_down ;;
  *) echo "usage: $0 up|status|down" >&2; exit 2 ;;
esac
