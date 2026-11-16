#!/bin/bash
# What WRITE sizes does the NFS client actually issue for fio bs = 512k/1M/4M/8M,
# and does a bigger block help at the FUSE layer?
set -uo pipefail
CSV=/home/ys1000/seaweedfs/logs/blocksize.csv
METRICS=http://127.0.0.1:32000/metrics
FIO=/usr/local/bin/fio
MNT=/mnt/bs-test
FUSE=/home/ys1000/seaweedfs/mnt

mdelta() {
  awk -v fa="$1" -v fb="$2" -v m="$3" -v p="${4:-}" '
    function accum(f,   line, key, v) {
      while ((getline line < f) > 0) {
        if (line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
        key = line; sub(/[ \t].*$/, "", key); sub(/\{.*$/, "", key)
        v = line; sub(/^[^ \t]*[ \t]+/, "", v)
        if (key==m && (p=="" || line ~ p)) { s += v + 0 }
      }
      close(f)
    }
    BEGIN { accum(fa); a=s; s=0; accum(fb); printf "%.0f", s-a }' 2>/dev/null
}
cputicks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
weed_pid() { local p; for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }; done; }

sudo mkdir -p "$MNT"
timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/seaweedfs "$MNT" >/dev/null 2>&1
grep -q " $MNT " /proc/mounts || { echo "MOUNT FAILED"; exit 1; }
echo "mounted: $(grep " $MNT " /proc/mounts | grep -oE 'rsize=[0-9]+|wsize=[0-9]+' | tr '\n' ' ')"

echo "layer,bs,MiB_s,IOPS,write_ops,bytes_per_write_KiB,ganesha_cpu_s,mount_cpu_s" > "$CSV"

run() { # <layer nfs|fuse> <bs> <size>
  local layer=$1 bs=$2 size=$3
  local dir
  [ "$layer" = "nfs" ] && dir=$MNT || dir=$FUSE
  local jf=/tmp/bs.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=1\niodepth=16\nsize=%s\n' "$bs" "$size"
    printf 'fallocate=none\n'
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=bs.%s.$jobnum\n' "$bs"
    printf '\n[bs]\nnumjobs=1\n'
  } > "$jf"

  local mp=$(weed_pid "-dir=$FUSE ") gp=$(pgrep -x ganesha.nfsd | head -1)
  curl -sS -m 10 "$METRICS" -o /tmp/bs-mb.txt 2>/dev/null
  local m0=$(cputicks $mp) g0=$(cputicks $gp)
  timeout 300 "$FIO" "$jf" > /tmp/bs.out 2>&1
  local rc=$?
  curl -sS -m 10 "$METRICS" -o /tmp/bs-ma.txt 2>/dev/null
  local m1=$(cputicks $mp) g1=$(cputicks $gp)

  local bw=$(grep -oE 'BW=[0-9.]+MiB/s' /tmp/bs.out | head -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'bw=[0-9.]+MiB/s' /tmp/bs.out | tail -1 | cut -d= -f2)
  local iops=$(grep -oE 'IOPS=[0-9.]+k?' /tmp/bs.out | head -1 | cut -d= -f2)
  local wop=$(mdelta /tmp/bs-mb.txt /tmp/bs-ma.txt "nfsv4__op_count" 'op="WRITE"')
  local mib=$(( $(echo "$size" | sed 's/G/*1024/;s/M//') ))
  local bpw=0
  [ "${wop:-0}" -gt 0 ] && bpw=$(echo "scale=1; $mib * 1024 / $wop" | bc)
  local gcpu=$(echo "scale=2; ($g1-$g0)/100" | bc)
  local mcpu=$(echo "scale=2; ($m1-$m0)/100" | bc)
  printf '%-5s bs=%-5s BW=%-10s IOPS=%-8s WRITEops=%-6s avg_write=%sKiB ganCPU=%-6s mntCPU=%-6s %s\n' \
    "$layer" "$bs" "${bw:-?}" "${iops:-?}" "${wop:-?}" "${bpw:-?}" "$gcpu" "$mcpu" "$([ "$rc" -ne 0 ] && echo FAIL)"
  echo "$layer,$bs,${bw:-0},${iops:-0},${wop:-0},${bpw:-0},$gcpu,$mcpu" >> "$CSV"
  for f in "$dir/bs.$bs".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
}

echo
echo "### NFS layer (wsize=1 MiB) ###"
for bs in 512k 1M 4M 8M; do run nfs "$bs" 1G; done
echo
echo "### direct FUSE layer (no NFS) ###"
for bs in 1M 4M 8M; do run fuse "$bs" 1G; done

echo
echo "CSV: $CSV"
cat "$CSV"
echo "BS DONE"
