#!/usr/bin/env bash
# Smoke test: validate the harness helpers + one tiny case
set -uo pipefail
# Shared helpers: pids_of. See LAB-CONVENTIONS.md R1.
. "$(dirname "$0")/lib-nfslab.sh"
METRICS=http://127.0.0.1:32000/metrics
DATA=/home/ys1000/seaweedfs/data

scrape() { curl -sS -m 10 "$METRICS" -o "$1" 2>/dev/null; }
mval() {
  awk -v m="$2" -v p="${3:-}" '
    { key=$1
      if (key==m || substr(key,1,length(m)+1)==m"{") {
        if (p=="" || $0 ~ p) { print $2; exit } } }' "$1" 2>/dev/null
}
mval_or() { local v; v=$(mval "$1" "$2" "${3:-}"); echo "${v:-0}"; }
cputicks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
    pid_of() { pids_of "$1" | head -1; }
volbytes() { cat "$DATA"/*.dat 2>/dev/null | wc -c; }

PID_GAN=$(pid_of "ganesha.nfsd -f")
PID_WMOUNT=$(pid_of "weed mount")
PID_WSRV=$(pid_of "weed server")
echo "pids ganesha=$PID_GAN mount=$PID_WMOUNT server=$PID_WSRV"

scrape /tmp/sm.txt
echo "metrics lines=$(wc -l < /tmp/sm.txt)"
echo "rpcs_received_total = $(mval_or /tmp/sm.txt rpcs_received_total)"
echo "rpcs_completed_total = $(mval_or /tmp/sm.txt rpcs_completed_total)"
echo "nfsv4__op_count(WRITE) = $(mval_or /tmp/sm.txt nfsv4__op_count 'op=\"WRITE\"')"
echo "nfsv4__op_latency_sum(WRITE) = $(mval_or /tmp/sm.txt nfsv4__op_latency_sum 'op=\"WRITE\"')"
echo "nfsv4__op_latency_count(WRITE) = $(mval_or /tmp/sm.txt nfsv4__op_latency_count 'op=\"WRITE\"')"
echo "cputicks ganesha=$(cputicks $PID_GAN) mount=$(cputicks $PID_WMOUNT)"
echo "volbytes=$(volbytes)"

echo
echo "=== tiny case: 256 MiB O_DIRECT through NFS ==="
mkdir -p /mnt/ganesha-test
b0=$(mval_or /tmp/sm.txt nfsv4__op_count 'op="WRITE"')
s0=$(mval_or /tmp/sm.txt nfsv4__op_latency_sum 'op="WRITE"')
c0=$(mval_or /tmp/sm.txt nfsv4__op_latency_count 'op="WRITE"')
r0=$(mval_or /tmp/sm.txt rpcs_received_total)
g0=$(cputicks $PID_GAN); w0=$(cputicks $PID_WMOUNT); v0=$(cputicks $PID_WSRV)
d0=$(volbytes); t0=$(date +%s.%N)

/usr/local/bin/fio --directory=/mnt/ganesha-test --name=smoke --filename=smoke.$jobnum \
  --filename_format=smoke.$jobnum --size=256M --rw=write --bs=1M --ioengine=libaio \
  --iodepth=16 --numjobs=1 --direct=1 --group_reporting 2>&1 | grep -E "write: IOPS|BW=" | head -3

t1=$(date +%s.%N); scrape /tmp/sm2.txt
b1=$(mval_or /tmp/sm2.txt nfsv4__op_count 'op="WRITE"')
s1=$(mval_or /tmp/sm2.txt nfsv4__op_latency_sum 'op="WRITE"')
c1=$(mval_or /tmp/sm2.txt nfsv4__op_latency_count 'op="WRITE"')
r1=$(mval_or /tmp/sm2.txt rpcs_received_total)
g1=$(cputicks $PID_GAN); w1=$(cputicks $PID_WMOUNT); v1=$(cputicks $PID_WSRV)
d1=$(volbytes)
el=$(echo "$t1 - $t0" | bc)

echo "  WRITE ops      = $((b1-b0))"
echo "  avg lat ms     = $(echo "scale=3; (($s1-$s0)) / (($c1-$c0))" | bc 2>/dev/null)"
echo "  rpc delta      = $((r1-r0))  (rate/s = $(echo "scale=1; ($r1-$r0)/$el" | bc))"
echo "  ganesha CPU s  = $(echo "scale=1; ($g1-$g0)/100" | bc)"
echo "  fuse CPU s     = $(echo "scale=1; ($w1-$w0)/100" | bc)"
echo "  volserver CPU s= $(echo "scale=1; ($v1-$v0)/100" | bc)"
echo "  disk growth MiB= $(( (d1-d0)/1024/1024 ))"
find /mnt/ganesha-test -maxdepth 1 -name "smoke*" -delete 2>/dev/null
echo "  cleanup done"
