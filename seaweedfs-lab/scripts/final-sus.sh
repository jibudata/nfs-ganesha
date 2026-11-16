#!/bin/bash
# Final bounded sustained comparison.
#  * reset the A2 mount first (the previous 12 GiB run left its 4 GB write
#    buffer full and the mount blocked)
#  * fallocate=none  -> fio uses ftruncate, so the file layout costs nothing
#  * 6 GiB > the 4 GB write buffer, so the excess MUST be drained to the
#    volume server during the write
#  * hard timeout per case; a timeout is itself a result
set -uo pipefail
CSV=/home/ys1000/seaweedfs/logs/ssd-vs-hdd-sustained.csv
FIO=/usr/local/bin/fio
SIZE=${SIZE:-6G}
TIMEOUT=${TIMEOUT:-240}

tier_def() {
  case $1 in
    NVME_FRESH) echo "/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh|nvme0n1";;
    HDD)        echo "/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/home/ys1000/seaweedfs-hdd/data|sda";;
  esac
}
volbytes() { find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'; }
cputicks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
weed_pid() { local p; for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }; done; }

echo "=== reset the A2 mount (clear the stuck write buffer) ==="
sudo systemctl restart seaweedfs-mount-nvme-fresh
sleep 8
# Restarting the FUSE mount invalidates the export: Ganesha holds a dirfd to
# the old (now detached) mount, and writes through it are accepted by the
# kernel page cache and then lost - the client sees success, the volume
# server sees nothing. Ganesha must re-resolve the export before anything is
# measured through it. This step was missing when this script produced the
# voided "NVMe 1517 vs HDD 93" result (dat_delta = 0 on both tiers).
sudo systemctl restart ganesha
sleep 3
python3 -c "
import os
try:
    os.stat('/home/ys1000/seaweedfs/mnt-nvme-fresh'); print('  A2 FUSE ok')
except Exception as e: print('  A2 FUSE BAD', e)
"
du -sm /home/ys1000/seaweedfs/cache-nvme-fresh 2>/dev/null

echo "tier,size,MiB_s,elapsed_s,effective_MiB_s,dat_delta_mib,timeout" > "$CSV"

for t in NVME_FRESH HDD; do
  IFS='|' read -r fm np dd dev <<< "$(tier_def "$t")"
  MNT=/mnt/fin-$t
  sudo mkdir -p "$MNT"
  timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$np" "$MNT" >/dev/null 2>&1
  grep -q " $MNT " /proc/mounts || { echo "  $t mount failed"; continue; }

  jf=/tmp/fin.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=1M\ndirect=0\niodepth=16\nsize=%s\n' "$SIZE"
    printf 'fallocate=none\n'
    printf 'directory=%s\n' "$MNT"
    printf 'filename_format=fin.%s.$jobnum\n' "$t"
    printf '\n[fin]\nnumjobs=1\n'
    printf 'end_fsync=1\n'
  } > "$jf"

  vp=$(weed_pid "-dir=$dd "); v0=$(cputicks $vp); d0=$(volbytes "$dd")
  t0=$(date +%s.%N)
  timeout "$TIMEOUT" "$FIO" "$jf" > /tmp/fin-fio.out 2>&1
  rc=$?
  t1=$(date +%s.%N)
  v1=$(cputicks $vp); d1=$(volbytes "$dd")

  el=$(echo "$t1 - $t0" | bc)
  bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/fin-fio.out | head -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/fin-fio.out | tail -1 | cut -d= -f2)
  size_mib=$(( $(echo "$SIZE" | sed 's/G/*1024/') ))
  eff=$(echo "scale=1; $size_mib / $el" | bc)
  dmb=$(( (d1 - d0)/1024/1024 ))
  vcpu=$(echo "scale=2; ($v1 - $v0)/100" | bc)
  to=$([ "$rc" -eq 124 ] && echo yes || echo no)
  printf '%-11s size=%-4s fioBW=%-10s el=%-8ss effective=%-8s MiB/s volCPU=%-7ss dat+%sMiB timeout=%s\n' \
    "$t" "$SIZE" "${bw:-?}" "$el" "$eff" "$vcpu" "$dmb" "$to"
  echo "$t,$SIZE,${bw:-0},$el,$eff,$dmb,$to" >> "$CSV"

  for f in "$MNT/fin.$t".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
  ( sudo umount -l "$MNT" >/dev/null 2>&1 ) &
  sleep 8
done
echo "FINAL SUS DONE"
