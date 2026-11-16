#!/usr/bin/env bash
# Quick end-to-end NFS throughput probe (Target D of the perf matrix)
set -uo pipefail

M=/mnt/ganesha-test
echo "=== fio over NFSv4.1 (1MB rsize/wsize, local client on the same host) ==="
/usr/local/bin/fio --directory="$M" --name=nfs-seqwrite --filename=nfs-bench \
  --size=4G --rw=write --bs=1M --ioengine=libaio --iodepth=16 --numjobs=1 \
  --group_reporting --direct=1 2>&1 | grep -E "write: IOPS|^  WRITE:|fio-|error" | head -5

echo
echo "=== same shape, buffered (no O_DIRECT) ==="
/usr/local/bin/fio --directory="$M" --name=nfs-seqwrite-buf --filename=nfs-bench2 \
  --size=4G --rw=write --bs=1M --ioengine=libaio --iodepth=16 --numjobs=1 \
  --group_reporting 2>&1 | grep -E "write: IOPS|^  WRITE:|fio-|error" | head -5

echo
echo "=== Ganesha Prometheus metrics endpoint (127.0.0.1:32000) ==="
curl -sS -m 10 http://127.0.0.1:32000/metrics 2>&1 | grep -E "^ganesha_(nfs|rpc)_" | head -12
echo "  ..."
curl -sS -m 10 http://127.0.0.1:32000/metrics 2>&1 | grep -c "^ganesha_"

echo
echo "=== cleanup ==="
rm -f "$M/nfs-bench" "$M/nfs-bench2"
echo "  done"
