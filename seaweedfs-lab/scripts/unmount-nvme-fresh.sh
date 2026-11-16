#!/usr/bin/env bash
set -uo pipefail
# Read the kernel mount table instead of calling mountpoint: mountpoint does a
# stat(2) on the path, which blocks in D state on a wedged mount.
is_mounted() {
  awk -v p="/home/ys1000/seaweedfs/mnt-nvme-fresh" '$2 == p { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}
if is_mounted; then
  # Bounded with a timeout rather than backgrounded: systemd's default
  # KillMode=control-group kills a backgrounded unmount the moment ExecStop
  # exits, so it would never finish.
  timeout 15 fusermount3 -u "/home/ys1000/seaweedfs/mnt-nvme-fresh" 2>/dev/null \
    || ( timeout 15 sudo umount -l "/home/ys1000/seaweedfs/mnt-nvme-fresh" 2>/dev/null ) \
    || true
fi
exit 0
