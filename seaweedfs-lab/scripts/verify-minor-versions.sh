#!/usr/bin/env bash
# Verify the NFSv4 minor-version pinning: v4.1 must work, v4.2 must be refused.
set -uo pipefail

SRV=192.168.3.146
T41=/mnt/ganesha-v41
T42=/mnt/ganesha-v42
T3=/mnt/ganesha-v3

# Shared helpers: is_mounted / lazy_unmount. See LAB-CONVENTIONS.md R2/R3.
# "$(dirname "$0")" so the script works from any working directory.
. "$(dirname "$0")/lib-nfslab.sh"

echo "=== NFSv4.1 mount (must succeed) ==="
sudo mkdir -p "$T41"
lazy_unmount "$T41"
if sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     "$SRV:/seaweedfs" "$T41" 2>&1; then
  echo "  v4.1 mount: OK"
  is_mounted "$T41" && echo "  mount confirmed"
  echo "  --- negotiated ---"
  nfsstat -m 2>/dev/null | grep -A2 "$T41" | head -3
  echo "  --- read/write through v4.1 ---"
  dd if=/dev/urandom of="$T41/v41-probe" bs=1M count=8 conv=fsync 2>&1 | tail -1
  md5sum "$T41/v41-probe"
  rm -f "$T41/v41-probe"
else
  echo "  v4.1 mount: FAILED (unexpected)"
fi

echo
echo "=== NFSv4.2 mount (must be refused) ==="
sudo mkdir -p "$T42"
lazy_unmount "$T42"
if sudo mount -t nfs -o vers=4.2,proto=tcp,rsize=1048576,wsize=1048576 \
     "$SRV:/seaweedfs" "$T42" 2>&1; then
  echo "  v4.2 mount: SUCCEEDED -- pinning NOT effective"
  is_mounted "$T42" && echo "  (mounted)"
else
  echo "  v4.2 mount: refused as expected"
fi
is_mounted "$T42" && { echo "  cleanup"; lazy_unmount "$T42"; }

echo
echo "=== NFSv3 mount (must still work) ==="
sudo mkdir -p "$T3"
lazy_unmount "$T3"
if sudo mount -t nfs -o vers=3,proto=tcp "$SRV:/seaweedfs" "$T3" 2>&1; then
  echo "  v3 mount: OK"
  is_mounted "$T3" && lazy_unmount "$T3"
else
  echo "  v3 mount: failed"
fi

echo
echo "=== ganesha log: minor version handling ==="
sudo grep -iE "minor vers|MINOR_VERS" /var/log/ganesha/ganesha.log | tail -5
