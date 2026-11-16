#!/bin/bash
# =====================================================================
# Sustained-write test: the only case where the STORAGE DEVICE can show up.
#
# All the A/B cases above wrote <= 512 MiB, which fits in SeaweedFS's 4 GB
# write buffer AND in the kernel page cache, so the bytes never had to reach
# the platter -- the tier numbers measured "how fast can the volume server
# accept a chunk upload", not "how fast can the disk absorb data".
#
# Here we write 12 GiB (3x the write buffer) and measure:
#   * the total elapsed time (includes the final flush to the device)
#   * the device's average write rate during the case (iostat)
# =====================================================================
set -uo pipefail

CSV=/home/ys1000/seaweedfs/logs/ssd-vs-hdd-sustained.csv
FIO=/usr/local/bin/fio
SIZE=${SIZE:-12G}
REPS=${REPS:-2}

tier_def() {
  case $1 in
    NVME_FRESH) echo "/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh|nvme0n1";;
    HDD)        echo "/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/home/ys1000/seaweedfs-hdd/data|sda";;
  esac
}
weed_pid() {
  local p
  for p in $(pgrep -x weed); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }
  done
}
cputicks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
volbytes() {
  find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'
}

echo "tier,rep,size,MiB_s,elapsed_s,volume_cpu_s,dat_delta_mib,device,dev_write_MiB_s,dev_util_pct" > "$CSV"

for rep in $(seq 1 $REPS); do
  for t in NVME_FRESH HDD; do
    IFS='|' read -r fm np dd dev <<< "$(tier_def "$t")"
    MNT=/mnt/sus-$t-$rep
    sudo mkdir -p "$MNT"
    timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
         "192.168.3.146:$np" "$MNT" >/dev/null 2>&1
    if ! grep -q " $MNT " /proc/mounts; then
      echo "  $t: mount failed, skip"
      continue
    fi

    jf=/tmp/sus.fio
    {
      printf '[global]\n'
      printf 'ioengine=libaio\nrw=write\nbs=1M\ndirect=0\niodepth=16\nsize=%s\n' "$SIZE"
      printf 'directory=%s\n' "$MNT"
      printf 'filename_format=sus.%s.$jobnum\n' "$t"
      printf '\n[sus]\nnumjobs=1\n'
      printf 'end_fsync=1\n'
    } > "$jf"

    vp=$(weed_pid "-dir=$dd ")
    v0=$(cputicks $vp); d0=$(volbytes "$dd")
    t0=$(date +%s.%N)

    # sample the device write rate while the case runs
    timeout 3000 iostat -dx 1 > /tmp/sus-iostat.txt 2>&1 &
    IOP=$!

    timeout 2400 "$FIO" "$jf" > /tmp/sus-fio.out 2>&1
    rc=$?
    t1=$(date +%s.%N)

    kill $IOP 2>/dev/null; wait $IOP 2>/dev/null

    v1=$(cputicks $vp); d1=$(volbytes "$dd")
    el=$(echo "$t1 - $t0" | bc)
    bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/sus-fio.out | head -1 | cut -d= -f2)
    [ -z "$bw" ] && bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/sus-fio.out | tail -1 | cut -d= -f2)
    mib=$(echo "scale=2; $el" | bc)
    size_mib=$(( $(echo "$SIZE" | sed 's/G/*1024/') ))
    [ "$mib" -gt 0 ] && eff=$(echo "scale=1; $size_mib / $mib" | bc) || eff=0
    dmb=$(( (d1 - d0)/1024/1024 ))
    vcpu=$(echo "scale=2; ($v1 - $v0)/100" | bc)

    # device write rate over the window (from the last iostat block)
    dw=$(awk -v d="$dev" '$1==d {w=wkB/1024; u=$NF} END{printf "%.0f %.1f", w, u}' /tmp/sus-iostat.txt 2>/dev/null)

    printf '%-11s rep%s size=%-4s fioBW=%-10s effective=%-8s MiB/s el=%-7ss volCPU=%-7ss dat+%sMiB  dev=%s %s\n' \
      "$t" "$rep" "$SIZE" "${bw:-?}" "$eff" "$el" "$vcpu" "$dmb" "$dev" "$dw"
    echo "$t,$rep,$SIZE,${bw:-0},$el,$vcpu,$dmb,$dev,$(echo $dw | cut -d' ' -f1),$(echo $dw | cut -d' ' -f2)" >> "$CSV"

    for f in "$MNT/sus.$t".*; do [ -e "$f" ] && rm -f "$f"; done
    rm -f "$jf"
    ( sudo umount -l "$MNT" >/dev/null 2>&1 ) &
    sleep 5
  done
done

echo "CSV: $CSV"
echo "SUSTAINED DONE"
