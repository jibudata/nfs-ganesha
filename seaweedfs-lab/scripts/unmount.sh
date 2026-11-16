#!/usr/bin/env bash
# Unmount the SeaweedFS FUSE mount cleanly (systemd ExecStop)
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

# Read the kernel mount table instead of calling mountpoint: mountpoint does a
# stat(2) on the path, and a stat on a wedged FUSE mount blocks in D state.
# This script runs as the systemd ExecStop, where a hang means the unit never
# stops. /proc/mounts is a table read and never blocks.
is_mounted() {
  awk -v p="$SW_MNT" '$2 == p { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

if is_mounted; then
  # fusermount3 is the clean path; the lazy umount is the fallback for a
  # mount that no longer answers. Both are bounded by a timeout, so a wedged
  # mount cannot block the unit stop. Backgrounding is not an option here:
  # systemd's KillMode=control-group would kill the job before it finished.
  timeout 15 fusermount3 -u "$SW_MNT" 2>/dev/null \
    || ( timeout 15 sudo umount -l "$SW_MNT" 2>/dev/null ) \
    || true
fi
exit 0
