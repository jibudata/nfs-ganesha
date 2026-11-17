#!/bin/bash
# =====================================================================
# Final benchmark on a HEALTHY stack.
#   * block-size sweep at the NFS layer and at the FUSE layer
#   * full CPU accounting for all five processes on the path
#   * every case verifies that the bytes actually reached the volume
#     server (.dat growth) -- a case whose bytes do not land is void
#
# Tick deltas are pure bash integer arithmetic; awk is used only for the
# float divisions. (An earlier version joined /proc snapshots with awk
# across files and produced nonsense; this version reads the counters
# directly into shell variables, the same way the validated ab3.sh does.)
# =====================================================================
set -uo pipefail

# R27: fio_clat_ms - the unit is read out of fio's section header and the
# value is normalised to milliseconds.  See LAB-CONVENTIONS.md R27.
. "$(dirname "$0")/lib-nfslab.sh"

CSV=${CSV:-/home/ys1000/seaweedfs/logs/final-bench.csv}
FUSE_MNT=/home/ys1000/seaweedfs/mnt-nvme-fresh
DATA_DIR=/home/ys1000/seaweedfs/data-nvme-fresh
FIO=/usr/local/bin/fio
SIZE=${SIZE:-512M}
METRICS=http://127.0.0.1:32000/metrics

ticks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
rss_kb(){ [ -n "${1:-}" ] && awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
weed_pid() {
  local p
  for p in $(pgrep -x weed); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$1" && { echo "$p"; return; }
  done
}
pid_master() { for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "weed master" && tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "-port=9533" && { echo "$p"; return; }; done; }
pid_filer()  { for p in $(pgrep -x weed); do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "weed filer"  && tr '\0' ' ' < "/proc/$p/cmdline" | grep -q -- "-port=9088" && { echo "$p"; return; }; done; }
pid_vol()    { weed_pid "-dir=$DATA_DIR "; }
pid_mount()  { weed_pid "-dir=$FUSE_MNT "; }
pid_ganesha(){ pgrep -x ganesha.nfsd | head -1; }
volbytes()  { find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'; }
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

GP=$(pid_ganesha); MP=$(pid_mount); VP=$(pid_vol); FP=$(pid_filer); AP=$(pid_master)
echo "pids: ganesha=$GP mount=$MP volume=$VP filer=$FP master=$AP"
if [ -z "$GP" ] || [ -z "$MP" ] || [ -z "$VP" ]; then echo "MISSING PID - abort"; exit 1; fi

run_case() { # <label> <layer> <bs> <size> <direct> <njobs> [fio args...]
  local label=$1 layer=$2 bs=$3 size=$4 direct=$5 nj=$6; shift 6
  local extra=("$@")
  local dir
  [ "$layer" = "nfs" ] && dir=$NM || dir=$FUSE_MNT
  local jf=/tmp/fb-$label.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\nfallocate=none\n' "$bs" "$direct" "$size"
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in ${extra+"${extra[@]}"}; do printf '%s\n' "$a"; done
  } > "$jf"

  local g0=$(ticks $GP) m0=$(ticks $MP) v0=$(ticks $VP) f0=$(ticks $FP) a0=$(ticks $AP)
  local rg0=$(rss_kb $GP) rm0=$(rss_kb $MP) rv0=$(rss_kb $VP) rf0=$(rss_kb $FP) ra0=$(rss_kb $AP)
  local d0=$(volbytes "$DATA_DIR")
  local t0=$(date +%s.%N)
  scrape /tmp/fb-mb.txt

  timeout 600 "$FIO" "$jf" > /tmp/fb-$label.out 2>&1
  local rc=$?
  local t1=$(date +%s.%N)

  # let the chunk upload finish, then snapshot
  local wait=0 stable=0 last=$(volbytes "$DATA_DIR")
  while [ $wait -lt 30 ]; do
    sleep 1; wait=$((wait+1))
    local now=$(volbytes "$DATA_DIR")
    if [ "$now" = "$last" ]; then stable=$((stable+1)); [ $stable -ge 3 ] && break; else stable=0; last=$now; fi
  done

  local g1=$(ticks $GP) m1=$(ticks $MP) v1=$(ticks $VP) f1=$(ticks $FP) a1=$(ticks $AP)
  local rg1=$(rss_kb $GP) rm1=$(rss_kb $MP) rv1=$(rss_kb $VP) rf1=$(rss_kb $FP) ra1=$(rss_kb $AP)
  local d1=$(volbytes "$DATA_DIR")
  scrape /tmp/fb-ma.txt

  local bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' /tmp/fb-$label.out | tail -1 | cut -d= -f2)
  # R27: the unit is read out of the header and the value is normalised to
  # milliseconds - "tr -d 'clat ():'" turns "usec" into "use".
  local cunit=ms
  local clat=$(fio_clat_ms /tmp/fb-$label.out)
  local err=$(grep -oE 'err= *[0-9]+' /tmp/fb-$label.out | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')
  local iob=$(grep -oE 'io=[0-9.]+[KMG]iB' /tmp/fb-$label.out | tail -1 | cut -d= -f2)
  local mib=0
  case "$iob" in *KiB) mib=$(echo "${iob%KiB}/1024"|bc);; *MiB) mib=$(echo "${iob%MiB}"|bc);; *GiB) mib=$(echo "${iob%GiB}*1024"|bc);; esac
  local wsum=$(mdelta /tmp/fb-mb.txt /tmp/fb-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  local wcnt=$(mdelta /tmp/fb-mb.txt /tmp/fb-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  local glat=0
  [ "$(echo "$wcnt > 0"|bc)" -eq 1 ] && glat=$(echo "scale=3; $wsum/$wcnt"|bc)
  local el=$(echo "$t1 - $t0"|bc)
  local landed=$(( (d1-d0)/1048576 ))

  # CPU seconds (ticks -> seconds)
  local cg=$(awk -v a=$g0 -v b=$g1 'BEGIN{printf "%.3f",(b-a)/100}')
  local cm=$(awk -v a=$m0 -v b=$m1 'BEGIN{printf "%.3f",(b-a)/100}')
  local cv=$(awk -v a=$v0 -v b=$v1 'BEGIN{printf "%.3f",(b-a)/100}')
  local cf=$(awk -v a=$f0 -v b=$f1 'BEGIN{printf "%.3f",(b-a)/100}')
  local ca=$(awk -v a=$a0 -v b=$a1 'BEGIN{printf "%.3f",(b-a)/100}')
  local ct=$(awk -v g=$cg -v m=$cm -v v=$cv -v f=$cf -v a=$ca 'BEGIN{printf "%.3f", g+m+v+f+a}')
  local gib=$(awk -v m=$mib 'BEGIN{printf "%.4f", m/1024}')
  local pg=$(awk -v c=$ct -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local pgg=$(awk -v c=$cg -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local pgm=$(awk -v c=$cm -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local pgv=$(awk -v c=$cv -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local pgf=$(awk -v c=$cf -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local pga=$(awk -v c=$ca -v g=$gib 'BEGIN{printf "%.3f", c/g}')
  local rsssum=$(awk -v a=$rg1 -v b=$rm1 -v c=$rv1 -v d=$rf1 -v e=$ra1 'BEGIN{printf "%.1f",(a+b+c+d+e)/1024}')

  # R9 sanity: CPU seconds cannot exceed elapsed * ncpu. A larger value means
  # the counter arithmetic is broken, not that the machine did that much work.
  local ncpu=$(nproc)
  local cpubad=0
  awk -v c="$ct" -v e="$el" -v n="$ncpu" 'BEGIN { exit (c > e*n) }' || cpubad=1
  # R4 sanity: the case is void unless the bytes reached the volume server
  local void=0
  [ "$landed" -lt $((mib/2)) ] && void=1

  printf '%-22s BW=%-9s clat=%s%-4s ganWlat=%-8s el=%-6ss wrote=%sMiB landed=%sMiB %s\n' \
    "$label" "${bw:-0}" "${clat:-0}" "${cunit:-?}" "$glat" "$el" "$mib" "$landed" \
    "$([ "$void" -eq 1 ] && echo '*** DATA DID NOT LAND - CASE IS VOID ***')"
  printf '    CPU-s: ganesha=%s mount=%s volume=%s filer=%s master=%s TOTAL=%s   CPU-s/GiB: total=%s (g=%s m=%s v=%s f=%s a=%s)\n' \
    "$cg" "$cm" "$cv" "$cf" "$ca" "$ct" "$pg" "$pgg" "$pgm" "$pgv" "$pgf" "$pga"
  [ "$cpubad" -eq 1 ] && printf '    *** CPU ACCOUNTING BROKEN: %s CPU-s in %ss on %s cores - counters are wrong ***\n' "$ct" "$el" "$ncpu"
  printf '    RSS(after): ganesha=%sMB mount=%sMB volume=%sMB filer=%sMB master=%sMB total=%sMB\n' \
    "$(awk -v x=$rg1 'BEGIN{printf "%.0f",x/1024}')" "$(awk -v x=$rm1 'BEGIN{printf "%.0f",x/1024}')" \
    "$(awk -v x=$rv1 'BEGIN{printf "%.0f",x/1024}')" "$(awk -v x=$rf1 'BEGIN{printf "%.0f",x/1024}')" \
    "$(awk -v x=$ra1 'BEGIN{printf "%.0f",x/1024}')" "$rsssum"

  echo "$label,$layer,$bs,$nj,$direct,${bw:-0},${clat:-0},${cunit:-?},$glat,$el,$mib,$landed,$cg,$cm,$cv,$cf,$ca,$ct,$pg,$pgg,$pgm,$pgv,$pgf,$pga,$rsssum,$err,$rc,void=$void,cpubad=$cpubad" >> "$CSV"

  for f in "$dir/$label".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
  sleep 2
}

echo "label,layer,bs,njobs,direct,BW,clat_avg_ms,clat_unit,ganesha_wlat_ms,elapsed_s,wrote_mib,landed_mib,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,filer_cpu_s,master_cpu_s,total_cpu_s,total_per_gib,g_ganesha,g_mount,g_volume,g_filer,g_master,rss_total_mb,io_err,fio_rc" > "$CSV"
echo "### final bench: $(date -Is) size=$SIZE ###"

NM="/mnt/fb-$$"
sudo mkdir -p "$NM"
timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
  "192.168.3.146:/seaweedfs-nvme-fresh" "$NM" >/dev/null 2>&1 && echo "mounted $NM" || { echo "MOUNT FAILED"; exit 1; }

echo
echo "######## NFS layer: block size sweep (wsize=1M, buffered + end_fsync) ########"
run_case nfs_bs512k nfs 512k "$SIZE" 0 1 end_fsync=1
run_case nfs_bs1M   nfs 1M   "$SIZE" 0 1 end_fsync=1
run_case nfs_bs4M   nfs 4M   "$SIZE" 0 1 end_fsync=1
run_case nfs_bs8M   nfs 8M   "$SIZE" 0 1 end_fsync=1

echo
echo "######## NFS layer: O_DIRECT (stable writes) ########"
run_case nfs_odirect1M nfs 1M "$SIZE" 1 1
run_case nfs_odirect8M nfs 8M "$SIZE" 1 1

echo
echo "######## NFS layer: concurrency (8 jobs x 1M, separate files) ########"
run_case nfs_8job1M nfs 1M 64M 0 8 end_fsync=1

echo
echo "######## FUSE layer: block size sweep ########"
run_case fuse_bs1M fuse 1M "$SIZE" 1 1
run_case fuse_bs4M fuse 4M "$SIZE" 1 1
run_case fuse_bs8M fuse 8M "$SIZE" 1 1

( sudo umount -l "$NM" >/dev/null 2>&1 ) &
sleep 2
rm -f /tmp/fb-*.fio /tmp/fb-*.out /tmp/fb-m*.txt
echo "CSV: $CSV"
echo "done: $(date -Is)"
