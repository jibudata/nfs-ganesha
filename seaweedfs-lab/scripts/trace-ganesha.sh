#!/bin/bash
# Trace what Ganesha actually does on the FUSE file during an NFS write.
set -uo pipefail

MNT=/mnt/ganesha-test
GPID=$(pgrep -x ganesha.nfsd | head -1)
echo "ganesha pid=$GPID"

# Shared helpers: is_mounted / lazy_unmount. See LAB-CONVENTIONS.md R2/R3.
. "$(dirname "$0")/lib-nfslab.sh"

sudo mkdir -p "$MNT"
lazy_unmount "$MNT"
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/seaweedfs "$MNT" || { echo "MOUNT FAILED"; exit 1; }

rm -f /tmp/trace.txt
# trace the syscalls that touch the exported (FUSE) file
sudo timeout 40 strace -f -p "$GPID" -tt -s 32 \
     -e trace=pwrite64,pwritev,pread64,preadv,fsync,fdatasync,openat,write \
     -o /tmp/trace.txt &
STRACE_PID=$!
sleep 4

/usr/local/bin/fio --name=t --rw=write --bs=1M --size=256M --direct=1 \
  --ioengine=libaio --iodepth=16 \
  --directory="$MNT" --filename_format='tracewrite.$jobnum' \
  > /tmp/trace-fio.out 2>&1
grep -E 'write: IOPS|WRITE: bw=' /tmp/trace-fio.out | sed 's/^/fio: /'

sleep 2
sudo kill $STRACE_PID 2>/dev/null
wait $STRACE_PID 2>/dev/null

for f in "$MNT/tracewrite".*; do [ -e "$f" ] && rm -f "$f"; done

echo
echo "=== syscall summary (counts) ==="
awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[a-z_0-9]+\(/ && $i !~ /^\(/) { print $i; break } }' /tmp/trace.txt \
  | sed 's/(.*//' | sort | uniq -c | sort -rn | head -20

echo
echo "=== pwrite64/pwritev return-value distribution ==="
grep -E 'pwrite(v|64)?\(' /tmp/trace.txt \
  | grep -oE '= -?[0-9]+$' | sort | uniq -c | sort -rn | head -15

echo
echo "=== short writes (returned < requested) ==="
grep -E 'pwrite(v|64)?\(' /tmp/trace.txt | awk '{
    req=0; ret=0
    for (i=1;i<=NF;i++) {
      if ($i ~ /^[0-9]+,/) { split($i,a,","); if (a[1]+0>req) req=a[1]+0 }
      if ($i ~ /^= -?[0-9]+$/) { v=$i; sub(/^= /,"",v); ret=v+0 }
    }
    if (req>0) { n++; if (ret<req) short++; bytes+=ret }
  } END { printf "pwrite calls=%d short=%d total_ret_bytes=%d\n", n+0, short+0, bytes+0 }'

echo
echo "=== pread on the export? (would mean read-modify-write) ==="
grep -cE 'pread' /tmp/trace.txt
echo "--- sample preads ---"
grep -E 'pread' /tmp/trace.txt | head -8

echo
echo "=== fsync/fdatasync count ==="
grep -cE 'fsync|fdatasync' /tmp/trace.txt

echo
echo "=== sample of the write sequence (first 25) ==="
grep -E 'pwrite(v|64)?\(' /tmp/trace.txt | head -25

lazy_unmount "$MNT"
rm -f /tmp/trace-fio.out
echo "TRACE DONE"
