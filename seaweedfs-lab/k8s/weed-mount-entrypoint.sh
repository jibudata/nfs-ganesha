#!/usr/bin/env bash
# SeaweedFS FUSE mount sidecar for the Ganesha benchmark Pod.
set -euo pipefail

SW_BIN=${SW_BIN:-/usr/local/bin/weed}
FILER=${FILER:-172.18.255.52:19344}
MNT=${MNT:-/mnt/seaweedfs}
CACHE=${CACHE:-/cache}
LOG=${LOG:-/var/log/weed-mount.log}

mkdir -p "$MNT" "$CACHE"
"$SW_BIN" mount \
  -filer="$FILER" \
  -dir="$MNT" \
  -volumeName=seaweedfs-ganesha-pod \
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
  -dlm >"$LOG" 2>&1 &
mount_pid=$!
cleanup() {
  kill "$mount_pid" 2>/dev/null || true
  wait "$mount_pid" 2>/dev/null || true
  fusermount3 -u -z "$MNT" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

for _ in $(seq 1 90); do
  if awk -v p="$MNT" '$2 == p && $3 == "fuse.seaweedfs" { found=1 } END { exit !found }' /proc/mounts; then
    echo "SeaweedFS FUSE mounted at $MNT from $FILER"
    wait "$mount_pid"
    exit $?
  fi
  if ! kill -0 "$mount_pid" 2>/dev/null; then
    echo "ERROR: weed mount exited before mounting; log follows" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 1
done

echo "ERROR: FUSE mount did not become ready; log follows" >&2
cat "$LOG" >&2
exit 1
