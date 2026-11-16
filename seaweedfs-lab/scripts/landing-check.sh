#!/bin/bash
# =====================================================================
# Decisive experiment on the CURRENT (restarted) stack.
#
# Question: when data written through NFS actually reaches the volume
# server, and which write mode makes it happen.
#
# For each case we record:
#   * volume .dat growth (bytes that reached the disk)
#   * the filer's view of the file (does the metadata exist?)
#   * mount / volume / filer CPU
#   * the mount's RSS (how much data is sitting in its RAM write buffer)
# at +1s, +5s, +15s, +45s
# =====================================================================
set -uo pipefail

FUSE_MNT=/home/ys1000/seaweedfs/mnt-nvme-fresh
DATA_DIR=/home/ys1000/seaweedfs/data-nvme-fresh
FILER_PORT=9088
FIO=/usr/local/bin/fio

ticks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
rss()   { [ -n "${1:-}" ] && awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
weed_pid() {
  local p
  for p in $(pgrep -x weed); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }
  done
}
MP_=$(weed_pid "-dir=$FUSE_MNT ")
VP=$(weed_pid "-dir=$DATA_DIR ")
FP=$(weed_pid "-port=$FILER_PORT")
GP=$(pgrep -x ganesha.nfsd | head -1)
volbytes() { find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'; }
filer_entry() { # returns "http_code chunks"
  local code
  code=$(curl -s -m 8 -o /tmp/fe.json -w "%{http_code}" -H "Accept: application/json" "http://127.0.0.1:$FILER_PORT$1")
  local n=0
  [ -s /tmp/fe.json ] && n=$(grep -o '"fid"' /tmp/fe.json 2>/dev/null | wc -l)
  echo "http=$code chunks=$n"
}

echo "pids: mount=$MP_ volume=$VP filer=$FP ganesha=$GP"
echo "mount RSS at start: $(( $(rss $MP_) /1024 )) MB"

run() { # <label> <dir> <size> <direct> <extra-fio-args...>
  local label=$1 dir=$2 size=$3 direct=$4; shift 4
  local extra=("$@")
  local jf=/tmp/fin-$label.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=1M\ndirect=%s\niodepth=16\nsize=%s\nfallocate=none\n' "$direct" "$size"
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=1\n' "$label"
    for a in ${extra+"${extra[@]}"}; do printf '%s\n' "$a"; done
  } > "$jf"

  local d0=$(volbytes "$DATA_DIR") m0=$(ticks $MP_) v0=$(ticks $VP) f0=$(ticks $FP)
  local r0=$(rss $MP_)
  echo "--- $label dir=$dir size=$size direct=$direct ${extra[*]:-}"
  timeout 300 "$FIO" "$jf" > /tmp/fin-$label.out 2>&1
  local rc=$?
  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/fin-$label.out | tail -1 | cut -d= -f2)
  echo "    fio rc=$rc BW=${bw:-?}"
  local t=1
  for w in 1 4 10 30; do
    sleep $w; t=$((t+w))
    local d1=$(volbytes "$DATA_DIR") m1=$(ticks $MP_) v1=$(ticks $VP) f1=$(ticks $FP) r1=$(rss $MP_)
    printf "    +%3ss: datDelta=%5s MiB  mountCPU=%5st volumeCPU=%5st filerCPU=%4st  mountRSS=%s MB\n" \
      "$t" "$(( (d1-d0)/1048576 ))" "$((m1-m0))" "$((v1-v0))" "$((f1-f0))" "$((r1/1024))"
  done
  echo "    filer view of $label.0 : $(filer_entry "/$label.0")"
  rm -f "$jf" "$dir/$label.0"
  sleep 2
}

echo
echo "################ A) control: direct write to the FUSE mount ################"
run ctrl_fuse "$FUSE_MNT" 64M 1

echo
echo "################ B) NFS + O_DIRECT (client stable writes) ################"
NM="/mnt/fin-$$"
sudo mkdir -p "$NM"
timeout 30 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
  "192.168.3.146:/seaweedfs-nvme-fresh" "$NM" >/dev/null 2>&1 && echo "mounted" || echo "MOUNT FAILED"
run nfs_odirect "$NM" 64M 1

echo
echo "################ C) NFS buffered + end_fsync ################"
run nfs_buffered "$NM" 64M 0 end_fsync=1

echo
echo "################ D) NFS buffered, no fsync, file closed by fio ################"
run nfs_buffered_nofsync "$NM" 64M 0

( sudo umount -l "$NM" >/dev/null 2>&1 ) &
sleep 1
rm -f /tmp/fin-*.out /tmp/fe.json
echo done
