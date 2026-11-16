#!/bin/bash
# =====================================================================
# Sustained-write test v2 -- the only case where the STORAGE DEVICE shows up.
#
# All the short cases (<= 512 MiB) fit in SeaweedFS's 4 GB write buffer and
# in the kernel page cache, so the bytes never have to reach the platter:
# they measure "how fast can the volume server accept a chunk upload".
# To make the device visible the write must exceed the write buffer.
#
# v2 changes over v1:
#   * fallocate=none  (v1 used fio's default posix -> preallocation, which
#                      creates filer chunk metadata for the whole range)
#   * every case asserts the bytes actually reached the volume server
#   * a health probe runs between cases; a wedged mount is detected and
#     recovered before the next case can produce fiction
#   * CPU is accounted for all five processes and bounded by elapsed*ncpu
#   * tiers are interleaved (A/B/A/B) so drift hits both equally
# =====================================================================
set -uo pipefail

CSV=${CSV:-/home/ys1000/seaweedfs/logs/sustained-v2.csv}
FIO=/usr/local/bin/fio
SIZE=${SIZE:-6G}
REPS=${REPS:-2}
CASE_TIMEOUT=${CASE_TIMEOUT:-1800}

tier_def() {
  case $1 in
    NVME_FRESH) echo "/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh|nvme0n1";;
    HDD)        echo "/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/home/ys1000/seaweedfs-hdd/data|sda";;
  esac
}
ticks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
weed_pid() {
  local p
  for p in $(pgrep -x weed); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }
  done
}
pid_master() { for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "weed master" && tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "-port=9533" && { echo "$p"; return; }; done; }
pid_filer()  { for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "weed filer"  && tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "-port=9088" && { echo "$p"; return; }; done; }
pid_vol()    { weed_pid "-dir=$DATA_DIR "; }
volbytes() {
  find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'
}
is_mounted() { grep -q " $1 " /proc/mounts; }

# health probe: can this export still write bytes that reach the volume server?
# usage: probe_health <tier> <data dir>   (the export pseudo comes from $PSEUDO)
probe_health() { # <tier> <data dir>
  local tier=$1 dd=$2
  local p="/mnt/probe-$tier-$$"
  sudo mkdir -p "$p"
  timeout 30 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$PSEUDO" "$p" >/dev/null 2>&1 || { echo "    probe: mount failed"; return 1; }
  local d0=$(volbytes "$dd")
  # NON-ZERO data on purpose: SeaweedFS stores all-zero chunks as references,
  # so a /dev/zero probe would never grow the .dat even though the write was
  # accepted. A landing probe that writes zeros always false-negatives.
  dd if=/dev/urandom of="$p/health.bin" bs=1M count=16 conv=fsync >/dev/null 2>&1
  local rc=$?
  sleep 3
  local d1=$(volbytes "$dd")
  local delta=$(( (d1-d0)/1048576 ))
  rm -f "$p/health.bin"
  ( sudo umount -l "$p" >/dev/null 2>&1 ) &
  echo "    probe $tier: dd_rc=$rc landed=${delta}MiB"
  [ "$delta" -ge 8 ] && return 0 || return 1
}

run_case() { # <tier> <rep>
  local t=$1 rep=$2
  IFS='|' read -r fm np dd dev <<< "$(tier_def "$t")"
  local DATA_DIR="$dd"
  local MNT="/mnt/sus2-$t-$rep-$$"
  sudo mkdir -p "$MNT"
  timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$np" "$MNT" >/dev/null 2>&1
  if ! is_mounted "$MNT"; then echo "  $t rep$rep: mount failed, skip"; return 1; fi

  local jf=/tmp/sus2.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=1M\ndirect=0\niodepth=16\nsize=%s\nfallocate=none\n' "$SIZE"
    printf 'directory=%s\n' "$MNT"
    printf 'filename_format=sus2.%s.$jobnum\n' "$t"
    printf '\n[sus2]\nnumjobs=1\nend_fsync=1\n'
  } > "$jf"

  local VP=$(pid_vol) MP=$(weed_pid "-dir=$fm ") FP=$(pid_filer) AP=$(pid_master) GP=$(pgrep -x ganesha.nfsd | head -1)
  local v0=$(ticks $VP) m0=$(ticks $MP) f0=$(ticks $FP) a0=$(ticks $AP) g0=$(ticks $GP)
  local d0=$(volbytes "$dd")
  local t0=$(date +%s.%N)

  timeout "$CASE_TIMEOUT" "$FIO" "$jf" > /tmp/sus2-fio.out 2>&1
  local rc=$?
  local t1=$(date +%s.%N)

  # drain: wait until the volume stops growing
  local wait=0 stable=0 last=$(volbytes "$dd")
  while [ $wait -lt 120 ]; do
    sleep 2; wait=$((wait+2))
    local now=$(volbytes "$dd")
    if [ "$now" = "$last" ]; then stable=$((stable+1)); [ $stable -ge 3 ] && break; else stable=0; last=$now; fi
  done

  local v1=$(ticks $VP) m1=$(ticks $MP) f1=$(ticks $FP) a1=$(ticks $AP) g1=$(ticks $GP)
  local d1=$(volbytes "$dd")
  local el=$(echo "$t1 - $t0" | bc)
  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/sus2-fio.out | tail -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/sus2-fio.out | head -1 | cut -d= -f2)
  local err=$(grep -oE 'err= *[0-9]+' /tmp/sus2-fio.out | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')
  local size_mib=$(( $(echo "$SIZE" | sed 's/G/*1024/') ))
  local eff=$(echo "scale=1; $size_mib / $el" | bc)
  local landed=$(( (d1-d0)/1048576 ))
  local cg=$(awk -v a=$g0 -v b=$g1 'BEGIN{printf "%.2f",(b-a)/100}')
  local cm=$(awk -v a=$m0 -v b=$m1 'BEGIN{printf "%.2f",(b-a)/100}')
  local cv=$(awk -v a=$v0 -v b=$v1 'BEGIN{printf "%.2f",(b-a)/100}')
  local cf=$(awk -v a=$f0 -v b=$f1 'BEGIN{printf "%.2f",(b-a)/100}')
  local ca=$(awk -v a=$a0 -v b=$a1 'BEGIN{printf "%.2f",(b-a)/100}')
  local ct=$(awk -v g=$cg -v m=$cm -v v=$cv -v f=$cf -v a=$ca 'BEGIN{printf "%.2f",g+m+v+f+a}')
  local ncpu=$(nproc)
  local cpubad=0
  awk -v c="$ct" -v e="$el" -v n="$ncpu" 'BEGIN{exit (c > e*n)}' || cpubad=1
  local void=0
  [ "$landed" -lt $((size_mib/2)) ] && void=1

  printf '%-11s rep%s %-4s fioBW=%-10s effective=%-8s MiB/s el=%-7ss landed=%5sMiB/%sMiB %s\n' \
    "$t" "$rep" "$SIZE" "${bw:-?}" "$eff" "$el" "$landed" "$size_mib" \
    "$([ "$void" -eq 1 ] && echo '*** DATA DID NOT LAND - CASE IS VOID ***')"
  printf '    CPU-s: ganesha=%s mount=%s volume=%s filer=%s master=%s TOTAL=%s (bound elapsed*%s=%s)\n' \
    "$cg" "$cm" "$cv" "$cf" "$ca" "$ct" "$ncpu" "$(echo "$el * $ncpu" | bc)"
  [ "$cpubad" -eq 1 ] && printf '    *** CPU ACCOUNTING BROKEN ***\n'

  echo "$t,$rep,$SIZE,${bw:-0},$eff,$el,$landed,$size_mib,$cg,$cm,$cv,$cf,$ca,$ct,$err,$rc,void=$void,cpubad=$cpubad" >> "$CSV"

  for f in "$MNT/sus2.$t".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
  ( sudo umount -l "$MNT" >/dev/null 2>&1 ) &
  sleep 3
}

echo "tier,rep,size,fio_BW,effective_MiB_s,elapsed_s,landed_mib,size_mib,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,filer_cpu_s,master_cpu_s,total_cpu_s,io_err,fio_rc,void,cpubad" > "$CSV"
echo "### sustained v2: $(date -Is) size=$SIZE reps=$REPS ###"

for rep in $(seq 1 $REPS); do
  for t in NVME_FRESH HDD; do
    IFS='|' read -r fm np dd dev <<< "$(tier_def "$t")"
    PSEUDO=$np
    DATA_DIR=$dd
    echo "--- rep $rep : $t ---"
    probe_health "$t" "$dd" || echo "    !! health probe FAILED for $t -- run scripts/recover-fuse.sh before trusting results"
    run_case "$t" "$rep"
  done
done

( for m in $(awk '{print $2}' /proc/mounts | grep -E '^/mnt/sus2-'); do
    ( sudo umount -l "$m" >/dev/null 2>&1 ) &
  done )
sleep 2
rm -f /tmp/sus2-fio.out /tmp/sus2.fio
echo "CSV: $CSV"
echo "SUSTAINED V2 DONE: $(date -Is)"
