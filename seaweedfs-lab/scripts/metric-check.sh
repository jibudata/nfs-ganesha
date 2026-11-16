#!/bin/bash
set -uo pipefail
source <(sed -n '1,/^ROW=/p' /home/ys1000/seaweedfs/scripts/bench-write-io.sh)
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

lazy_unmount /mnt/ganesha-test
sudo mkdir -p /mnt/ganesha-test
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/seaweedfs /mnt/ganesha-test

scrape /tmp/mt1.txt
/usr/local/bin/fio --name=t --rw=write --bs=1M --size=128M --direct=1 \
  --ioengine=libaio --iodepth=16 \
  --directory=/mnt/ganesha-test --filename_format='metriccheck.$jobnum' \
  > /tmp/fio-metric.out 2>&1
scrape /tmp/mt2.txt

echo "WRITE op_count delta = $(mdelta /tmp/mt1.txt /tmp/mt2.txt 'nfsv4__op_count' 'op="WRITE"')"
echo "WRITE lat_sum delta = $(mdelta /tmp/mt1.txt /tmp/mt2.txt 'nfsv4__op_latency_sum' 'op="WRITE"')"
echo "WRITE lat_cnt delta = $(mdelta /tmp/mt1.txt /tmp/mt2.txt 'nfsv4__op_latency_count' 'op="WRITE"')"
echo "rpcs delta           = $(mdelta /tmp/mt1.txt /tmp/mt2.txt 'rpcs_received_total')"
echo "--- raw WRITE lines (note: status label splits the counter) ---"
grep -E 'nfsv4__op_(count|latency_sum)\{op="WRITE"' /tmp/mt2.txt
echo "--- fio ---"
grep -E 'write: IOPS=|WRITE: bw=' /tmp/fio-metric.out
echo "--- cleanup ---"
for f in /mnt/ganesha-test/metriccheck.*; do [ -e "$f" ] && rm -f "$f"; done
rm -f /tmp/fio-metric.out /tmp/mt1.txt /tmp/mt2.txt
echo DONE
