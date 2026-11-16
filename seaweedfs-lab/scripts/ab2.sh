#!/bin/bash
# =====================================================================
# Lean, self-healing SSD-vs-HDD comparison.
#
# Usage: ab2.sh <tier1> [<tier2> ...]
#   tier keys: NVME_FRESH | HDD | NVME_AGED
#
# Every case has a hard timeout; on timeout the script kills fio, remounts the
# NFS export and (if needed) restarts Ganesha, then continues.  The previous
# run wedged because a SeaweedFS chunk upload failed and NOTHING in the chain
# (FUSE -> Ganesha -> hard-mounted NFS client) has a timeout.
# =====================================================================
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

CSV=/home/ys1000/seaweedfs/logs/ssd-vs-hdd.csv
METRICS=http://127.0.0.1:32000/metrics
FIO=/usr/local/bin/fio
REPS=${REPS:-3}
CASE_TIMEOUT=${CASE_TIMEOUT:-240}

# key|fuse mount|nfs export path|nfs mount|volume data dir
TIER_DEF() {
  case $1 in
    NVME_FRESH) echo "/home/ys1000/seaweedfs/mnt-nvme-fresh|/seaweedfs-nvme-fresh|/mnt/ganesha-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh";;
    HDD)        echo "/home/ys1000/seaweedfs-hdd/mnt|/seaweedfs-hdd|/mnt/ganesha-hdd|/home/ys1000/seaweedfs-hdd/data";;
    NVME_AGED)  echo "/home/ys1000/seaweedfs/mnt|/seaweedfs|/mnt/ganesha-test|/home/ys1000/seaweedfs/data";;
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
remount_export() { # <nfs mount> <export path>
  # NEVER let umount/mount block: a hard-mounted NFS client whose server-side
  # export path disappeared blocks forever in umount(2).
  timeout 20 sudo umount -f "$1" >/dev/null 2>&1
  timeout 20 sudo umount -l "$1" >/dev/null 2>&1
  sleep 1
  sudo mkdir -p "$1"
  if timeout 30 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$2" "$1" >/dev/null 2>&1; then
    echo "    remounted $1"
  else
    echo "    REMOUNT FAILED $1"
    return 1
  fi
}
heal() { # <nfs mount> <export path> <tier>
  echo "    !! healing $3"
  pkill -x fio 2>/dev/null
  sleep 1
  # a wedged Ganesha export must be restarted, otherwise every later case hangs
  if ! systemctl is-active --quiet ganesha; then
    sudo systemctl restart ganesha; sleep 8
  fi
  remount_export "$1" "$2"
}

run_case() {
  local tier=$1 label=$2 mode=$3 nj=$4 bs=$5 size=$6 direct=$7
  local fm=$8 nm=$9 np=${10} dd=${11}; shift 11
  local extra=("$@")

  local mnt
  [ "$mode" = "nfs" ] && mnt=$nm || mnt=$fm

  local jf=/tmp/ab2-$label-$tier.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\n' "$bs" "$direct" "$size"
    printf 'directory=%s\n' "$mnt"
    printf 'filename_format=%s.%s.$jobnum\n' "$label" "$tier"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in ${extra+"${extra[@]}"}; do printf '%s\n' "$a"; done
  } > "$jf"

  local mp=$(weed_pid "-dir=$fm ") vp=$(weed_pid "-dir=$dd ") gp=$(pgrep -x ganesha.nfsd | head -1)
  scrape /tmp/ab2-mb.txt
  local g0=$(cputicks $gp) m0=$(cputicks $mp) v0=$(cputicks $vp) d0=$(volbytes "$dd")
  local t0=$(date +%s.%N)

  timeout "$CASE_TIMEOUT" "$FIO" "$jf" > /tmp/ab2-$label-$tier.out 2>&1
  local rc=$?

  local t1=$(date +%s.%N)
  scrape /tmp/ab2-ma.txt
  local g1=$(cputicks $gp) m1=$(cputicks $mp) v1=$(cputicks $vp) d1=$(volbytes "$dd")

  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/ab2-$label-$tier.out 2>/dev/null | tail -1 | cut -d= -f2)
  [ -z "$bw" ] && bw=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' /tmp/ab2-$label-$tier.out 2>/dev/null | head -1 | cut -d= -f2)
  local iops=$(grep -oE 'IOPS=[0-9.]+[kKmM]?' /tmp/ab2-$label-$tier.out 2>/dev/null | cut -d= -f2 | awk '{v=$0;m=1; if(v~/[kK]$/){m=1000;v=substr(v,1,length(v)-1)} else if(v~/[mM]$/){m=1000000;v=substr(v,1,length(v)-1)} s+=v*m} END{printf "%d", s+0}')
  local cunit=$(grep -oE 'clat \((msec|usec|nsec)\)' /tmp/ab2-$label-$tier.out 2>/dev/null | head -1 | tr -d 'clat ():')
  local clat=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' /tmp/ab2-$label-$tier.out 2>/dev/null | grep -oE 'avg=[0-9.]+' | head -1 | cut -d= -f2)
  local err=$(grep -oE 'err= *[0-9]+' /tmp/ab2-$label-$tier.out 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')

  local wsum=$(mdelta /tmp/ab2-mb.txt /tmp/ab2-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  local wcnt=$(mdelta /tmp/ab2-mb.txt /tmp/ab2-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  local glat=0
  [ "$(echo "$wcnt > 0" | bc)" -eq 1 ] && glat=$(echo "scale=3; $wsum / $wcnt" | bc)
  local rpc=$(mdelta /tmp/ab2-mb.txt /tmp/ab2-ma.txt "rpcs_received_total")
  local el=$(echo "$t1 - $t0" | bc)
  local rps=0; [ "$(echo "$el > 0" | bc)" -eq 1 ] && rps=$(echo "scale=1; $rpc / $el" | bc)
  local gcpu=$(echo "scale=2; ($g1 - $g0)/100" | bc)
  local mcpu=$(echo "scale=2; ($m1 - $m0)/100" | bc)
  local vcpu=$(echo "scale=2; ($v1 - $v0)/100" | bc)
  local dmb=$(( (d1 - d0)/1024/1024 ))

  printf '%-11s %-18s BW=%-9s IOPS=%-7s clat=%s%-4s wlat=%-8s rpc/s=%-7s ganCPU=%-5s mntCPU=%-5s volCPU=%-5s el=%-7ss dat+%sMiB%s\n' \
    "$tier" "$label" "${bw:-0}" "${iops:-0}" "${clat:-0}" "${cunit:-?}" "${glat}" "${rps}" "${gcpu}" "${mcpu}" "${vcpu}" "${el}" "$dmb" \
    "$([ "$rc" -ne 0 ] && echo '  <<TIMEOUT/FAIL rc='$rc'>>')"

  echo "$tier,$label,${bw:-0},${iops:-0},${clat:-0},${cunit:-?},${glat},${rps},${gcpu},${mcpu},${vcpu},${el},$dmb,${err:-0},$rc" >> "$CSV"

  for f in "$mnt/$label.$tier".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"

  if [ "$rc" -ne 0 ]; then
    heal "$nm" "$np" "$tier"
  fi
  sleep 3
}

echo "case,tier,MiB_s,IOPS,clat_avg,clat_unit,ganesha_avg_write_lat_ms,rpc_per_s,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,elapsed_s,dat_delta_mib,io_err,fio_rc" > "$CSV"

TIERS=("$@")
echo "### tiers: ${TIERS[*]} | reps=$REPS | case_timeout=${CASE_TIMEOUT}s | $(date -Is) ###"

for rep in $(seq 1 $REPS); do
  for t in "${TIERS[@]}"; do
    IFS='|' read -r fm np nm dd <<< "$(TIER_DEF "$t")"
    remount_export "$nm" "$np"
    echo "--- rep $rep : $t ---"
    run_case "$t" fuse_odirect     fuse 1 1M 512M 1 "$fm" "$nm" "$np" "$dd"
    run_case "$t" nfs_odirect      nfs  1 1M 512M 1 "$fm" "$nm" "$np" "$dd"
    run_case "$t" nfs_buf_endsync  nfs  1 1M 512M 0 "$fm" "$nm" "$np" "$dd" end_fsync=1
    run_case "$t" nfs_odirect_8job nfs  8 1M 64M  1 "$fm" "$nm" "$np" "$dd"
  done
done

for t in "${TIERS[@]}"; do
  IFS='|' read -r fm np nm dd <<< "$(TIER_DEF "$t")"
  lazy_unmount "$nm"
done
rm -f /tmp/ab2-*.fio /tmp/ab2-*.out /tmp/ab2-mb.txt /tmp/ab2-ma.txt
echo "CSV: $CSV"
echo "done: $(date -Is)"
