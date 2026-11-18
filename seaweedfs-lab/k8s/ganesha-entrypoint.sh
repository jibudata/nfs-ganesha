#!/usr/bin/env bash
# Mount SeaweedFS through FUSE and export it over NFS, in one container.
#
# Both halves share a single mount namespace on purpose.  The previous design
# mounted weed in a sidecar and let Ganesha receive the submount through
# Bidirectional/HostToContainer mount propagation; on Kind the submount never
# crossed the container boundary (runs 44051984700 and 44054244166: the fuse
# container showed fuse.seaweedfs in /proc/mounts, the Ganesha container kept
# the bare emptyDir, and the old wait loop timed out at 120 s, crash-looping
# the pod).  Mounting and serving in the same container needs no propagation
# at all, on any runtime.
set -euo pipefail

SW_BIN=${SW_BIN:-/usr/local/bin/weed}
FILER=${FILER:-172.18.255.52:19344}
MNT=${MNT:-/mnt/seaweedfs}
CACHE=${CACHE:-/cache}
LOG=${LOG:-/var/log/weed-mount.log}
CONF=${CONF:-/etc/ganesha/ganesha.conf}
# IO threads capped at 2x the vCPU count (default 16 for 8 vCPU).  The old
# 128-writer default oversubscribed a 4-vCPU node to load 36 and polluted
# every measurement; measure with the cap that matches the machine.
CONCURRENT_WRITERS=${CONCURRENT_WRITERS:-16}
CONCURRENT_READERS=${CONCURRENT_READERS:-16}
# Optional: a world-writable directory to create inside the export after
# the mount is up.  The export is Root_Squash and the FUSE root is owned
# by root with mode 0755, so an NFS client's root cannot create a file at
# the top level.  The FUSE root also rejects setattr (EAGAIN), so the
# chmod has to target a fresh SUBdirectory - the same workaround the CI
# smoke test uses.  Empty by default: the benchmark arm's behaviour is
# unchanged.
EXPORT_SUBDIR=${EXPORT_SUBDIR:-}

mount_visible() {
  awk -v p="$MNT" '$2 == p && $3 == "fuse.seaweedfs" { found=1 } END { exit !found }' /proc/mounts
}

mkdir -p "$MNT" "$CACHE" "$(dirname "$LOG")" /var/log/ganesha /var/run/ganesha /var/lib/nfs/ganesha
# FSAL VFS resolves the export path through /etc/mtab (src/FSAL/localfs.c,
# MOUNTED).  Docker recreates this symlink at container start, containerd
# (kubelet) does not, so carry it ourselves.
ln -snf /proc/mounts /etc/mtab
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
  -concurrentWriters="$CONCURRENT_WRITERS" \
  -concurrentReaders="$CONCURRENT_READERS" \
  -metadataFlushSeconds=120 \
  -fuse.maxBackground=128 \
  -fuse.congestionThreshold=0 \
  -df.logical \
  -dlm >"$LOG" 2>&1 &
mount_pid=$!

ganesha_pid=""
cleanup() {
  trap - EXIT TERM INT
  if [ -n "$ganesha_pid" ]; then
    kill "$ganesha_pid" 2>/dev/null || true
  fi
  kill "$mount_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  fusermount3 -u -z "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# Ganesha must not resolve the export until the FUSE mount exists in this
# namespace; a server that opens the bare directory first keeps a dirfd to it
# and later writes land outside the mount (the lab's R10 failure mode).
for _ in $(seq 1 90); do
  if mount_visible; then
    break
  fi
  if ! kill -0 "$mount_pid" 2>/dev/null; then
    echo "ERROR: weed mount exited before mounting; log follows" >&2
    cat "$LOG" >&2
    exit 1
  fi
  sleep 1
done
if ! mount_visible; then
  echo "ERROR: FUSE mount did not become ready; log follows" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "SeaweedFS FUSE mounted at $MNT from $FILER"

if [ -n "$EXPORT_SUBDIR" ]; then
  mkdir -p "$MNT/$EXPORT_SUBDIR"
  chmod 0777 "$MNT/$EXPORT_SUBDIR"
  echo "prepared writable export subdirectory $MNT/$EXPORT_SUBDIR"
fi

echo "starting Ganesha"

/usr/bin/ganesha.nfsd -F -f "$CONF" -N NIV_EVENT -L /dev/stderr &
ganesha_pid=$!

# If either half dies the other is serving or writing into a dead tree; tear
# the container down so the pod restarts cleanly instead of reporting stale
# success to the client.
wait -n "$mount_pid" "$ganesha_pid"
status=$?
echo "ERROR: ganesha-fuse supervisor exiting (status $status; mount pid $mount_pid, ganesha pid $ganesha_pid)" >&2
exit "$status"
