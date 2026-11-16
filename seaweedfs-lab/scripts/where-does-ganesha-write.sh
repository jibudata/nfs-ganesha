#!/bin/bash
# Final placement test: write a file over NFS, then look for it in EVERY
# candidate directory, including Ganesha's own export-root dirfds.
set -uo pipefail

GP=$(pgrep -x ganesha.nfsd | head -1)
echo "ganesha pid=$GP"

echo "=== export root dirfds of THIS instance ==="
for fd in /proc/$GP/fd/*; do
  t=$(sudo readlink "$fd" 2>/dev/null)
  case "$t" in /*) echo "  $(basename "$fd") -> $t";; esac
done

MP="/mnt/place-$$"
sudo mkdir -p "$MP"
timeout 30 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
  "192.168.3.146:/seaweedfs-nvme-fresh" "$MP" >/dev/null 2>&1 || { echo "MOUNT FAILED"; exit 1; }

# Non-zero data on purpose: SeaweedFS stores an all-zero chunk as a bare
# reference, so a zero write never grows the volume .dat. This script looks
# for the file itself rather than for .dat growth, but writing real bytes
# keeps it valid as a landing probe too.
dd if=/dev/urandom of="$MP/PLACEHOLDER.bin" bs=1M count=4 conv=fsync 2>&1 | tail -1
echo "client view: size=$(stat -c %s "$MP/PLACEHOLDER.bin" 2>/dev/null)"
echo

echo "=== where is PLACEHOLDER.bin ? ==="
CANDS=(
  "/"
  "/home/ys1000/seaweedfs/mnt"
  "/home/ys1000/seaweedfs/mnt-nvme-fresh"
  "/home/ys1000/seaweedfs-hdd"
  "/home/ys1000/seaweedfs-hdd/mnt"
  "/home/ys1000/ganesha-local-ext4"
  "/mnt"
)
for d in "${CANDS[@]}"; do
  if sudo ls "$d/PLACEHOLDER.bin" >/dev/null 2>&1; then
    echo "  FOUND in $d  size=$(sudo stat -c %s "$d/PLACEHOLDER.bin")"
  fi
done
echo "  (end of list)"

echo
echo "=== contents of each Ganesha export-root dirfd ==="
for fd in /proc/$GP/fd/*; do
  t=$(sudo readlink "$fd" 2>/dev/null)
  case "$t" in
    /*)
      echo "--- fd $(basename "$fd") -> $t"
      sudo ls -la "$fd/" 2>&1 | grep -vE "^total|^d.*\s\.\.?$" | head -8
      ;;
  esac
done

echo
echo "=== stat of the candidate dirs (device + inode) ==="
for d in "/" "/home/ys1000/seaweedfs/mnt-nvme-fresh" "/home/ys1000/seaweedfs-hdd" "/home/ys1000/seaweedfs-hdd/mnt"; do
  sudo stat -c "%d:%i  %F  %n" "$d" 2>&1
done
echo "=== ganesha dirfd stats ==="
for fd in /proc/$GP/fd/*; do
  t=$(sudo readlink "$fd" 2>/dev/null)
  case "$t" in /*) sudo stat -c "%d:%i  %n" "$fd" 2>&1;; esac
done

( sudo umount -l "$MP" >/dev/null 2>&1 ) &
sleep 1
echo done
