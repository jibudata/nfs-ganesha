#!/bin/bash
# =====================================================================
# SSD vs HDD comparison for the full chain:
#   NFS client -> Ganesha (FSAL_VFS) -> FUSE (SeaweedFS) -> filer -> volume -> disk
#
# Three tiers are compared, all served by the SAME Ganesha process and
# measured interleaved in one time window so device drift cancels out:
#
#   NVME_FRESH  volume chunks on the NVMe, brand-new cluster (state-controlled)
#   HDD         volume chunks on /dev/sda, brand-new cluster (identical config)
#   NVME_AGED   the original NVMe cluster, already carrying 9.8 GB of .dat and
#               a 44 MB filer LevelDB from the earlier benchmark matrix
#
# The point of NVME_FRESH vs NVME_AGED is to separate "device" from
# "cluster state" -- the aged cluster turned out to be SLOWER than the HDD
# one, which is only explicable by state.
# =====================================================================
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

CSV=/home/ys1000/seaweedfs/logs/ssd-vs-hdd.csv
METRICS=http://127.0.0.1:32000/metrics
FIO=/usr/local/bin/fio
REPS=3

# tier | fuse mount | nfs export path | nfs mount | volume data dir
TIERS=(
  "NVME_FRESH|/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/mnt/ganesha-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh"
  "HDD|/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/mnt/ganesha-hdd|/home/ys1000/seaweedfs-hdd/data"
  "NVME_AGED|/home/ys1000/seaweedfs/mnt|/seaweedfs|/mnt/ganesha-test|/home/ys1000/seaweedfs/data"
)

scrape() { curl -sS -m 10 "$METRICS" -o "$1" 2>/dev/null; }
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
    BEGIN { accum(fa); a=s; s=0; accum(fb); printf "%.6f", s-a }' 2>/dev/null
}
cputicks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
# find the pid of a weed process whose cmdline contains a needle
weed_pid() {
  local p
  for p in $(pgrep -x weed); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }
  done
}
volbytes() {
  find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END{printf "%d\n", s+0}'
}

# ---- cases: label | mode(nfs|fuse) | nj | bs | size | direct | extra fio opts
run_case() {
  local tier=$1 tag=$2 rep=$3 label=$4 mode=$5 nj=$6 bs=$7 size=$8 direct=$9
  shift 9
  local fuse_mnt=$1 nfs_mnt=$2 nfs_path=$3 data_dir=$4; shift 4

  local mnt
  if [ "$mode" = "nfs" ]; then
    mnt=$nfs_mnt
  else
    mnt=$fuse_mnt
  fi

  local jf=/tmp/ab-$label-$tag.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\n' "$bs" "$direct"
    if [ "$nj" -gt 1 ]; then printf 'iodepth=16\n'; else printf 'iodepth=16\n'; fi
    printf 'size=%s\n' "$size"
    printf 'directory=%s\n' "$mnt"
    printf 'filename_format=%s.%s.$jobnum\n' "$label" "$tag"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in "$@"; do printf '%s\n' "$a"; done
  } > "$jf"

  local mp=$(weed_pid "-dir=$fuse_mnt ") vp=$(weed_pid "-dir=$data_dir ") gp=$(pgrep -x ganesha.nfsd | head -1)
  scrape /tmp/ab-mb.txt
  local g0=$(cputicks $gp) m0=$(cputicks $mp) v0=$(cputicks $vp) d0=$(volbytes "$data_dir")
  local t0=$(date +%s.%N)

  timeout 1200 "$FIO" "$jf" > /tmp/ab-$label-$tag.out 2>&1
  local rc=$?

  local t1=$(date +%s.%N)
  scrape /tmp/ab-ma.txt
  local g1=$(cputicks $gp) m1=$(cputicks $mp) v1=$(cputicks $vp) d1=$(volbytes "$data_dir")

  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/ab-$label-$tag.out | tail -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/ab-$label-$tag.out | head -1 | cut -d= -f2)
  local iops=$(grep -oE 'IOPS=[0-9.]+[kKmM]?' /tmp/ab-$label-$tag.out | cut -d= -f2 | awk '{v=$0;m=1; if(v~/[kK]$/){m=1000;v=substr(v,1,length(v)-1)} else if(v~/[mM]$/){m=1000000;v=substr(v,1,length(v)-1)} s+=v*m} END{printf "%d", s+0}')
  # R27: the unit is read out of the header and the value is normalised to
  # milliseconds - "tr -d 'clat ():'" turns "usec" into "use".
  local cunit=ms
  local clat=$(fio_clat_ms /tmp/ab-$label-$tag.out)
  local err=$(grep -oE 'err= *[0-9]+' /tmp/ab-$label-$tag.out | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')

  local wsum=$(mdelta /tmp/ab-mb.txt /tmp/ab-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  local wcnt=$(mdelta /tmp/ab-mb.txt /tmp/ab-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  local glat=0
  [ "$(echo "$wcnt > 0" | bc)" -eq 1 ] && glat=$(echo "scale=3; $wsum / $wcnt" | bc)
  local rpc=$(mdelta /tmp/ab-mb.txt /tmp/ab-ma.txt "rpcs_received_total")
  local el=$(echo "$t1 - $t0" | bc)
  local rps=0; [ "$(echo "$el > 0" | bc)" -eq 1 ] && rps=$(echo "scale=1; $rpc / $el" | bc)

  local gcpu=$(echo "scale=2; ($g1 - $g0)/100" | bc)
  local mcpu=$(echo "scale=2; ($m1 - $m0)/100" | bc)
  local vcpu=$(echo "scale=2; ($v1 - $v0)/100" | bc)
  local dmb=$(( (d1 - d0)/1024/1024 ))

  printf '%-11s rep%-2s %-20s BW=%-10s IOPS=%-8s clat=%s%s avgWriteLat=%-9s rpc/s=%-8s ganCPU=%-6s mountCPU=%-6s volCPU=%-6s el=%ss dat+%sMiB\n' \
    "$tier" "$rep" "$label" "${bw:-0}" "${iops:-0}" "${clat:-0}" "${cunit:-?}" "${glat}" "${rps}" "${gcpu}" "${mcpu}" "${vcpu}" "${el}" "$dmb"

  echo "$tier,$rep,$label,${bw:-0},${iops:-0},${clat:-0},${cunit:-?},${glat},${rps},${gcpu},${mcpu},${vcpu},${el},$dmb,$err" >> "$CSV"

  for f in "$mnt/$label.$tag".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
}

echo "case,MIb_s,IOPS,clat_avg_ms,clat_unit,ganesha_avg_write_lat_ms,rpc_per_s,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,elapsed_s,dat_delta_mib,io_err" > "$CSV"

echo "### mounting NFS exports ###"
for t in "${TIERS[@]}"; do
  IFS='|' read -r tier fm np nm dd <<< "$t"
  lazy_unmount "$nm"
  sudo mkdir -p "$nm"
  if sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$np" "$nm" 2>/dev/null; then
    echo "  $tier mounted at $nm ($np)"
  else
    echo "  $tier MOUNT FAILED"
  fi
done

echo
echo "### interleaved runs: $(date -Is) ###"
for rep in $(seq 1 $REPS); do
  for t in "${TIERS[@]}"; do
    IFS='|' read -r tier fm np nm dd <<< "$t"
    echo "--- rep $rep : $tier ---"
    run_case "$tier" "$tier" "$rep" fuse_odirect      fuse 1 1M  512M 1 "$fm" "$nm" "$np" "$dd"
    run_case "$tier" "$tier" "$rep" nfs_odirect       nfs  1 1M  512M 1 "$fm" "$nm" "$np" "$dd"
    run_case "$tier" "$tier" "$rep" nfs_buf_endsync   nfs  1 1M  1G    0 "$fm" "$nm" "$np" "$dd" end_fsync=1
    run_case "$tier" "$tier" "$rep" nfs_odirect_8job  nfs  8 1M  128M  1 "$fm" "$nm" "$np" "$dd"
  done
done

echo
echo "### cleanup ###"
for t in "${TIERS[@]}"; do
  IFS='|' read -r tier fm np nm dd <<< "$t"
  lazy_unmount "$nm"
done
rm -f /tmp/ab-*.fio /tmp/ab-*.out /tmp/ab-mb.txt /tmp/ab-ma.txt
echo "CSV: $CSV"
echo "done: $(date -Is)"
