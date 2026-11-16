#!/usr/bin/env bash
# End-to-end smoke test: NFS client -> Ganesha(FSAL_VFS) -> SeaweedFS FUSE -> volume server
#
# Run as a NON-root user: the export uses Root_Squash, so a root client is
# mapped to "nobody" and cannot write into the FUSE mount (owned by ys1000).
set -uo pipefail

M=/mnt/ganesha-test
DATA=/home/ys1000/seaweedfs/data
FUSE=/home/ys1000/seaweedfs/mnt

before=$(cat "$DATA"/*.dat 2>/dev/null | wc -c)

echo "=== write 128 MiB through NFS (client uid=$(id -u) $(id -un)) ==="
dd if=/dev/urandom of="$M/nfs-probe" bs=1M count=128 conv=fsync 2>&1 | tail -1

echo "=== md5 seen through NFS ==="
md5sum "$M/nfs-probe"

echo "=== same file visible directly on the FUSE mount? ==="
ls -l "$FUSE/nfs-probe" 2>&1 | tail -1
md5sum "$FUSE/nfs-probe" 2>&1

echo "=== did it reach the volume server? ==="
after=$(cat "$DATA"/*.dat 2>/dev/null | wc -c)
echo "  volume .dat growth: $(( (after - before) / 1024 / 1024 )) MiB (expect ~128)"

echo "=== read back through NFS ==="
md5sum "$M/nfs-probe"

echo "=== file metadata through NFS ==="
stat -c "nfs-probe size=%s mtime=%y" "$M/nfs-probe"

echo "=== cleanup ==="
rm -f "$M/nfs-probe"
echo "  done"
