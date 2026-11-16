#!/bin/bash
# =====================================================================
# docker-fuse-mount.sh - the FUSE gateway for the containerised arm.
#
# Runs on the HOST, like the bare-metal mount, and points at the filer that
# runs inside the container (published on 127.0.0.1:19344).  Ganesha and
# the FUSE gateway are therefore identical in every arm of the comparison;
# only the storage backend differs.
#
#   usage: bash docker-fuse-mount.sh up|down|status
#
# The flags are the bare-metal ones from scripts/mount.sh.  If a flag is
# changed here, it has to be changed there too.
#
# r10-exempt: this script does not restart an existing seaweedfs-mount*
# service, it creates a separate mount for a separate backend.
# =====================================================================
set -uo pipefail

. "$(dirname "$0")/lib-nfslab.sh"

SW_BIN=${SW_BIN:-/usr/local/bin/weed}
MNT=${DOCKER_MNT:-/home/ys1000/seaweedfs/mnt-docker}
CACHE=${DOCKER_FUSE_CACHE:-/home/ys1000/seaweedfs/docker-fuse-cache}
FILER=${DOCKER_FILER:-127.0.0.1:19344}
LOG=${DOCKER_FUSE_LOG:-/home/ys1000/seaweedfs/logs/mount-docker.log}
ACTION=${1:-status}

case "$ACTION" in
up)
  if is_fuse_mounted "$MNT"; then
    echo "  $MNT is already a FUSE mount"
    exit 0
  fi
  mkdir -p "$MNT" "$CACHE" "$(dirname "$LOG")"
  echo "=== mounting $MNT from the containerised filer at $FILER ==="
  nohup "$SW_BIN" mount \
    -filer="$FILER" \
    -dir="$MNT" \
    -volumeName=seaweedfs \
    -allowOthers=true \
    -defaultPermissions=true \
    -umask=022 \
    -cacheDir="$CACHE" \
    -cacheCapacityMB=128 \
    -cacheMetaTtlSec=60 \
    -chunkSizeLimitMB=2 \
    -writeBufferSizeMB=4096 \
    -concurrentWriters=128 \
    -concurrentReaders=128 \
    -metadataFlushSeconds=120 \
    -fuse.maxBackground=128 \
    -fuse.congestionThreshold=0 \
    -df.logical \
    -dlm >> "$LOG" 2>&1 &
  disown

  # "is it mounted" must check the FILESYSTEM TYPE, not just that the path
  # is in /proc/mounts: a plain directory can be in the table as ext4 and
  # then every check passes while the FUSE mount is not there at all.
  for i in $(seq 1 30); do
    if is_fuse_mounted "$MNT"; then
      echo "  ok     $MNT is a fuse.seaweedfs mount after ${i}s"
      exit 0
    fi
    sleep 1
  done
  echo "ERROR: $MNT did not become a FUSE mount" >&2
  tail -20 "$LOG" >&2
  exit 1
  ;;

down)
  echo "=== unmounting $MNT ==="
  lazy_unmount "$MNT"
  echo "  done"
  ;;

status)
  if is_fuse_mounted "$MNT"; then
    echo "  $MNT is a fuse.seaweedfs mount"
  else
    echo "  $MNT is NOT a FUSE mount"
  fi
  awk -v p="$MNT" '$2 == p { print "  " $0 }' /proc/mounts
  echo "  filer: $FILER"
  ;;

*)
  echo "usage: $0 up|down|status" >&2
  exit 2
  ;;
esac
