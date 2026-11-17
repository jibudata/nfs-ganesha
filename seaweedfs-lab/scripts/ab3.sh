#!/bin/bash
# =====================================================================
# Lean, self-healing SSD-vs-HDD comparison (v3).
#
# Lessons from the two wedged runs, all encoded here:
#  * NEVER stat a mount point to test whether it is mounted: `mountpoint -q`
#    calls stat(2), which blocks in D state when the NFS client is wedged.
#    /proc/mounts is a kernel table read and never blocks.
#  * NEVER umount synchronously: umount(2) on a hard-mounted NFS client with
#    pending I/O blocks in uninterruptible sleep and cannot be killed.
#    Each tier/rep therefore gets its OWN mount point; we only ever add.
#  * Every case has a hard timeout; on timeout we kill fio and restart Ganesha.
#  * SeaweedFS master's 14-minute automatic vacuum sweep is disabled, because
#    a vacuum forces the volume server to compact volumes and resets in-flight
#    chunk uploads ("multipart: NextPart: unexpected EOF" -> FUSE blocks ->
#    Ganesha blocks -> NFS hard-mount client retries forever).
# =====================================================================
set -uo pipefail

# R27: fio_clat_ms - the unit is read out of fio's section header and the
# value is normalised to milliseconds.  See LAB-CONVENTIONS.md R27.
. "$(dirname "$0")/lib-nfslab.sh"

CSV=${CSV:-/home/ys1000/seaweedfs/logs/ssd-vs-hdd.csv}
METRICS=http://127.0.0.1:32000/metrics
FIO=/usr/local/bin/fio
REPS=${REPS:-3}
CASE_TIMEOUT=${CASE_TIMEOUT:-180}

tier_def() {
  case $1 in
    NVME_FRESH) echo "/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh";;
    HDD)        echo "/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/home/ys1000/seaweedfs-hdd/data";;
    NVME_AGED)  echo "/home/ys1000/seaweedfs/mnt|/seaweedfs|/home/ys1000/seaweedfs/data";;
  esac
}

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
is_mounted() { grep -q " $1 " /proc/mounts; }

mount_export() { # <mountpoint> <export path>
  local m=$1 p=$2
  sudo mkdir -p "$m"
  if timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$p" "$m" >/dev/null 2>&1; then
    echo "    mounted $m ($p)"
    return 0
  fi
  echo "    MOUNT FAILED $m ($p)"
  return 1
}

heal() { # <tier> <current mount point> <export path>
  echo "    !! heal $1"
  pkill -x fio 2>/dev/null
  sleep 1
  sudo systemctl restart ganesha >/dev/null 2>&1
  sleep 8
  # a wedged client mount can never be replaced in place -> use a new path
  NM="/mnt/ab-heal-$1-$(date +%s)"
  mount_export "$NM" "$3"
}

run_case() {
  local tier=$1 label=$2 mode=$3 nj=$4 bs=$5 size=$6 direct=$7
  local fm=$8 dd=${10}; shift 10
  local nm=$NM
  local extra=("$@")

  local mnt
  [ "$mode" = "nfs" ] && mnt=$nm || mnt=$fm

  local jf=/tmp/ab3-$label-$tier.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\n' "$bs" "$direct" "$size"
    printf 'directory=%s\n' "$mnt"
    printf 'filename_format=%s.%s.$jobnum\n' "$label" "$tier"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in ${extra+"${extra[@]}"}; do printf '%s\n' "$a"; done
  } > "$jf"

  local mp=$(weed_pid "-dir=$fm ") vp=$(weed_pid "-dir=$dd ") gp=$(pgrep -x ganesha.nfsd | head -1)
  scrape /tmp/ab3-mb.txt
  local g0=$(cputicks $gp) m0=$(cputicks $mp) v0=$(cputicks $vp) d0=$(volbytes "$dd")
  local t0=$(date +%s.%N)

  timeout "$CASE_TIMEOUT" "$FIO" "$jf" > /tmp/ab3-$label-$tier.out 2>&1
  local rc=$?

  local t1=$(date +%s.%N)
  scrape /tmp/ab3-ma.txt
  local g1=$(cputicks $gp) m1=$(cputicks $mp) v1=$(cputicks $vp) d1=$(volbytes "$dd")

  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/ab3-$label-$tier.out 2>/dev/null | tail -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/ab3-$label-$tier.out 2>/dev/null | head -1 | cut -d= -f2)
  local iops=$(grep -oE 'IOPS=[0-9.]+[kKmM]?' /tmp/ab3-$label-$tier.out 2>/dev/null | cut -d= -f2 | awk '{v=$0;m=1; if(v~/[kK]$/){m=1000;v=substr(v,1,length(v)-1)} else if(v~/[mM]$/){m=1000000;v=substr(v,1,length(v)-1)} s+=v*m} END{printf "%d", s+0}')
  # R27: the unit is read out of the header and the value is normalised to
  # milliseconds - "tr -d 'clat ():'" turns "usec" into "use".
  local cunit=ms
  local clat=$(fio_clat_ms /tmp/ab3-$label-$tier.out)
  local err=$(grep -oE 'err= *[0-9]+' /tmp/ab3-$label-$tier.out 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')

  local wsum=$(mdelta /tmp/ab3-mb.txt /tmp/ab3-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  local wcnt=$(mdelta /tmp/ab3-mb.txt /tmp/ab3-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  local glat=0
  [ "$(echo "$wcnt > 0" | bc)" -eq 1 ] && glat=$(echo "scale=3; $wsum / $wcnt" | bc)
  local rpc=$(mdelta /tmp/ab3-mb.txt /tmp/ab3-ma.txt "rpcs_received_total")
  local el=$(echo "$t1 - $t0" | bc)
  local rps=0; [ "$(echo "$el > 0" | bc)" -eq 1 ] && rps=$(echo "scale=1; $rpc / $el" | bc)
  local gcpu=$(echo "scale=2; ($g1 - $g0)/100" | bc)
  local mcpu=$(echo "scale=2; ($m1 - $m0)/100" | bc)
  local vcpu=$(echo "scale=2; ($v1 - $v0)/100" | bc)
  local dmb=$(( (d1 - d0)/1024/1024 ))

  printf '%-11s %-17s BW=%-9s IOPS=%-7s clat=%s%-4s wlat=%-8s rpc/s=%-7s ganCPU=%-5s mntCPU=%-5s volCPU=%-5s el=%-6ss dat+%sMiB%s\n' \
    "$tier" "$label" "${bw:-0}" "${iops:-0}" "${clat:-0}" "${cunit:-?}" "${glat}" "${rps}" "${gcpu}" "${mcpu}" "${vcpu}" "${el}" "$dmb" \
    "$([ "$rc" -ne 0 ] && echo "  <<FAIL rc=$rc>>")"

  echo "$tier,$label,${bw:-0},${iops:-0},${clat:-0},${cunit:-?},${glat},${rps},${gcpu},${mcpu},${vcpu},${el},$dmb,${err:-0},$rc" >> "$CSV"

  for f in "$mnt/$label.$tier".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"

  if [ "$rc" -ne 0 ]; then heal "$tier" "$nm" "$NP"; fi
  sleep 2
}

TIERS=("$@")
echo "case,tier,MiB_s,IOPS,clat_avg_ms,clat_unit,ganesha_avg_write_lat_ms,rpc_per_s,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,elapsed_s,dat_delta_mib,io_err,fio_rc" > "$CSV"
echo "### tiers: ${TIERS[*]} | reps=$REPS | timeout=${CASE_TIMEOUT}s | $(date -Is) ###"

for rep in $(seq 1 $REPS); do
  for t in "${TIERS[@]}"; do
    IFS='|' read -r fm np dd <<< "$(tier_def "$t")"
    NM="/mnt/ab-$t-$rep"
    NP=$np
    echo "--- rep $rep : $t ---"
    mount_export "$NM" "$np" || { echo "  skipping tier $t (mount failed)"; continue; }
    run_case "$t" fuse_odirect     fuse 1 1M 512M 1 "$fm" "$NM" "$dd"
    run_case "$t" nfs_odirect      nfs  1 1M 512M 1 "$fm" "$NM" "$dd"
    run_case "$t" nfs_buf_endsync  nfs  1 1M 512M 0 "$fm" "$NM" "$dd" end_fsync=1
    run_case "$t" nfs_odirect_8job nfs  8 1M 64M  1 "$fm" "$NM" "$dd"
  done
done

echo
echo "### lazy unmount of the throw-away client mounts (never synchronously) ###"
for m in $(awk '{print $2}' /proc/mounts | grep -E '^/mnt/ab-'); do
  ( sudo umount -l "$m" >/dev/null 2>&1 ) &
done
sleep 2
rm -f /tmp/ab3-*.fio /tmp/ab3-*.out /tmp/ab3-mb.txt /tmp/ab3-ma.txt
echo "CSV: $CSV"
echo "done: $(date -Is)"
