#!/usr/bin/env bash
# Do not let Ganesha resolve the export until the FUSE sidecar's mount is visible.
set -euo pipefail
MNT=${MNT:-/mnt/seaweedfs}
CONF=${CONF:-/etc/ganesha/ganesha.conf}
for _ in $(seq 1 120); do
  if awk -v p="$MNT" '$2 == p && $3 == "fuse.seaweedfs" { found=1 } END { exit !found }' /proc/mounts; then
    exec /usr/bin/ganesha.nfsd -F -f "$CONF" -N NIV_EVENT -L /dev/stderr
  fi
  sleep 1
done
echo "ERROR: $MNT is not a fuse.seaweedfs mount; refusing to start Ganesha" >&2
exit 1
