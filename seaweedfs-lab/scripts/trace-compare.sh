#!/bin/bash
# Compare Ganesha's syscall pattern (pwritev/fsync counts) across:
#   A) NFS -> FUSE  (O_DIRECT)
#   B) NFS -> FUSE  (buffered)
#   C) NFS -> ext4  (O_DIRECT)
# If (A) and (C) both fsync but only (A) is slow, the cost is the FUSE fsync
# (flush to weed volume server), not Ganesha.
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

GPID=$(pgrep -x ganesha.nfsd | head -1)
echo "ganesha pid=$GPID"

trace_case() { # <label> <mountpoint> <serverpath> <direct>
  local label=$1 mnt=$2 path=$3 direct=$4
  local tf=/tmp/tr-$label.txt

  sudo mkdir -p "$mnt"
  lazy_unmount "$mnt"
  sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$path" "$mnt" || { echo "$label: MOUNT FAILED"; return 1; }

  sudo timeout 40 strace -f -p "$GPID" -tt \
     -e trace=pwrite64,pwritev,fsync,fdatasync \
     -o "$tf" 2>/dev/null &
  local sp=$!
  sleep 3

  /usr/local/bin/fio --name=t --rw=write --bs=1M --size=256M --direct="$direct" \
    --ioengine=libaio --iodepth=16 \
    --directory="$mnt" --filename_format="tc.$label.\$jobnum" \
    > /tmp/tr-fio.out 2>&1
  local bw=$(grep -oE 'BW=[0-9.]+MiB/s' /tmp/tr-fio.out | head -1 | cut -d= -f2)
  local clat=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' /tmp/tr-fio.out | grep -oE 'avg=[0-9.]+' | head -1)

  sleep 2
  sudo kill $sp 2>/dev/null; wait $sp 2>/dev/null

  local npw=$(grep -c 'pwrite' "$tf" || echo 0)
  local nfs=$(grep -cE 'fsync|fdatasync' "$tf" || echo 0)
  local nfsync=$(grep -c 'fsync(' "$tf" || echo 0)
  local nfdata=$(grep -c 'fdatasync' "$tf" || echo 0)

  printf '%-22s fioBW=%-10s clat=%-14s pwritev=%-5s fsync=%-5s fdatasync=%-5s\n' \
     "$label" "${bw:-?}" "${clat:-?}" "$npw" "$nfsync" "$nfdata"

  for f in "$mnt/tc.$label".*; do [ -e "$f" ] && rm -f "$f"; done
  lazy_unmount "$mnt"
}

trace_case fuse_odirect  /mnt/ganesha-test /seaweedfs              1
trace_case fuse_buffered /mnt/ganesha-test /seaweedfs              0
trace_case ext4_odirect  /mnt/ganesha-local /local-ext4            1
trace_case ext4_buffered /mnt/ganesha-local /local-ext4            0

echo
echo "=== do the fsyncs target the export fd? (sample from fuse_odirect) ==="
grep -E 'fsync|fdatasync' /tmp/tr-fuse_odirect.txt | head -6
echo "=== interleaving sample: pwritev then fsync ==="
grep -E 'pwritev|fsync|fdatasync' /tmp/tr-fuse_odirect.txt | head -12

rm -f /tmp/tr-*.txt /tmp/tr-fio.out
echo "COMPARE DONE"
