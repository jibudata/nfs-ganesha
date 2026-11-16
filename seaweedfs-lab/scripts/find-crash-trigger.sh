#!/usr/bin/env bash
# Narrow down what makes ganesha.nfsd segfault
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"
SRV=192.168.3.146
M=/mnt/ganesha-crash

nr() { systemctl show ganesha -p NRestarts --value 2>/dev/null; }
show() { echo "    NRestarts=$(nr)  MainPID=$(systemctl show ganesha -p MainPID --value)"; }

step() { echo "--- $1 ---"; show; }

echo "baseline:"; show

echo
echo "=== A: mount v4.1 only ==="
sudo mkdir -p $M; lazy_unmount $M
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 $SRV:/seaweedfs $M 2>&1 | head -2
sleep 3; step "after v4.1 mount"

echo
echo "=== B: write 256 MiB over v4.1 ==="
dd if=/dev/urandom of=$M/c1 bs=1M count=256 conv=fsync 2>&1 | tail -1
sleep 3; step "after write"

echo
echo "=== C: unmount v4.1 ==="
lazy_unmount $M
sleep 5; step "after unmount"

echo
echo "=== D: mount v3 (real path) ==="
sudo mkdir -p $M
sudo mount -t nfs -o vers=3,proto=tcp $SRV:/home/ys1000/seaweedfs/mnt $M 2>&1 | head -2
sleep 3; step "after v3 mount"

echo
echo "=== E: write 256 MiB over v3 ==="
dd if=/dev/urandom of=$M/c3 bs=1M count=256 conv=fsync 2>&1 | tail -1
sleep 3; step "after v3 write"

echo
echo "=== F: unmount v3 ==="
lazy_unmount $M
sleep 5; step "after v3 unmount"

echo
echo "=== G: mount v4.2 (expected to be refused) ==="
sudo mkdir -p $M
sudo mount -t nfs -o vers=4.2,proto=tcp $SRV:/seaweedfs $M 2>&1 | head -2
sleep 5; step "after v4.2 attempt"

echo
echo "final:"; show
find $M -maxdepth 1 -name "c1" -o -maxdepth 1 -name "c3" 2>/dev/null | xargs -r rm -f
lazy_unmount $M
echo "done"
