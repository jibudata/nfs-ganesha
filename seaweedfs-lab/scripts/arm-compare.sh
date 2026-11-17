#!/bin/bash
# =====================================================================
# arm-compare.sh - bare metal vs Docker vs Kubernetes, same workload.
#
#   usage: bash arm-compare.sh
#
# WHAT IS BEING COMPARED
#
#   arm   storage plane            host -> filer            host -> chunks
#   ----  -----------------------   ---------------------   ----------------
#   bare  host processes, loopback  127.0.0.1:8888           loopback
#   dock  one Docker container      127.0.0.1:19344          Docker proxy
#   k8s   three pods in a cluster   172.18.255.52:19344      MetalLB -> DNAT
#
# Ganesha and the FUSE gateway are on the HOST in all three arms, and
# all three run the same SeaweedFS 4.54 binary on the same NVMe
# device.  The only variable is where the storage plane runs and how
# the host's FUSE mount reaches it.
#
# HOW THE RUN IS ORDERED
#
# The cases are INTERLEAVED and the arm order ROTATES every round:
#
#   round 1   bare, docker, k8s
#   round 2   docker, k8s, bare
#   round 3   k8s, bare, docker
#
# A single pass per arm would compare the first arm against whatever the
# machine was doing in the last five minutes.  Rotating the order
# means every arm gets the same number of first, middle and last
# positions, so a drift in the machine's mood cancels out.
#
# EVERY CASE IS VOID UNLESS THE BYTES LANDED
#
# The .dat growth is measured before and after each case, and a case
# whose bytes did not reach the volume server is marked void - whatever
# throughput it reported is then meaningless.  The probe data is NON-ZERO
# (/dev/urandom via fio's scramble_buffers): SeaweedFS stores an all-zero
# chunk as a reference only, so a zero-filled probe would not move the
# .dat size at all.  See LAB-CONVENTIONS.md R4/R4a.
#
# The Kubernetes arm's .dat files are measured from INSIDE the volume
# pod: the node may itself be a container, so there is no path on this
# host to look at.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

CSV=${CSV:-/home/ys1000/seaweedfs/logs/arm-compare.csv}
METRICS=${METRICS:-http://127.0.0.1:32000/metrics}
FIO=${FIO:-/usr/local/bin/fio}
SIZE=${SIZE:-128M}
CONC_SIZE=${CONC_SIZE:-16M}
ROUNDS=${ROUNDS:-3}
NM=${NM:-/mnt/armcmp-$$}
K8S_DATSIZE=${K8S_DATSIZE:-/home/ys1000/seaweedfs/scripts/k8s-volume-datsize.sh}

ARMS="bare docker k8s"
HOST_FAILED=0

# --- per-arm facts -------------------------------------------------------

arm_pseudo() {
  case "$1" in
    bare)   echo "/seaweedfs" ;;
    docker) echo "/seaweedfs-docker" ;;
    k8s)    echo "/seaweedfs-k8s" ;;
  esac
}

# The size of the arm's .dat files, in bytes.
#
# The Kubernetes arm's files are measured from inside the volume pod:
# the node may itself be a container, so there is no path on this host
# to look at, and a path that does not exist would report "no bytes
# landed" for a write that landed perfectly well.
arm_size() { # <arm>
  case "$1" in
    bare)   vol_datsize /home/ys1000/seaweedfs/data ;;
    docker) vol_datsize /home/ys1000/seaweedfs/docker-data ;;
    k8s)    bash "$K8S_DATSIZE" ;;
  esac
}

# --- health ---------------------------------------------------------------
#
# A BACKEND THAT DIED MUST BE CAUGHT BEFORE THE CASE, NOT AFTER IT.
#
# On 2026-11-16 the Docker arm's filer was killed - the host ran out of
# memory and the Go runtime's scavenger deadlocked against a FUSE write.
# The FUSE mount then kept retrying a connection that would never come
# back, the write never completed, the fio sat in D state, and the HOST
# became unusable: load 98, and `ps` stopped working because a write
# path held mmap_lock in write mode.
#
# So every case starts by asking the arm's three services for their
# health page.  A service that does not answer means the case is not
# run: the harness says so and moves on, instead of taking the host
# down with it.
arm_endpoints() { # <arm>
  case "$1" in
    bare)   echo "127.0.0.1:9333 127.0.0.1:8081 127.0.0.1:8888" ;;
    docker) echo "127.0.0.1:19340 127.0.0.1:19342 127.0.0.1:19344" ;;
    k8s)    echo "172.18.255.50:19340 172.18.255.51:19342 172.18.255.52:19344" ;;
  esac
}

arm_health() { # <arm> -> the failing endpoints, empty when the arm is healthy
  local ep code bad=""
  for ep in $(arm_endpoints "$1"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ep/healthz" 2>/dev/null)
    case "$code" in
      2*|3*) : ;;
      *) bad="$bad $ep(http ${code:-none})" ;;
    esac
  done
  echo "$bad"
}

# How much memory the host can still give, in MiB.
mem_available_mb() {
  awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# The pid of one of the arm's processes.
#
# The scope (host / docker / k8s) comes from the cgroup, because the
# arms run the same binary with the same flags in places: the bare
# master and the Docker master both say "weed master -port=9333".
arm_pid() { # <arm> <role>
  local arm=$1 role=$2 scope pid
  case "$role" in
    master)
      case "$arm" in
        bare)   scope=host;   set -- "-mdir=/home/ys1000/seaweedfs/master" "-port=9333" ;;
        docker) scope=docker; set -- "-mdir=/data/master" "-port=9333" ;;
        k8s)    scope=k8s;    set -- "-port=19340" ;;
      esac ;;
    volume)
      case "$arm" in
        bare)   scope=host;   set -- "-master.peers=127.0.0.1:9333" ;;
        docker) scope=docker; set -- "-volume.port=8081" ;;
        k8s)    scope=k8s;    set -- "-volume.port=19342" ;;
      esac ;;
    filer)
      case "$arm" in
        bare)   scope=host;   set -- "-master=127.0.0.1:9333" ;;
        docker) scope=docker; set -- "-port=8888" ;;
        k8s)    scope=k8s;    set -- "-port=19344" ;;
      esac ;;
    mount)
      # The FUSE gateway is on the HOST in every arm - that is the point.
      scope=host
      case "$arm" in
        bare)   set -- "-filer=127.0.0.1:8888" ;;
        docker) set -- "-filer=127.0.0.1:19344" ;;
        k8s)    set -- "-filer=172.18.255.52:19344" ;;
      esac ;;
  esac
  for pid in $(weed_pid_matching "$@"); do
    [ "$(proc_scope "$pid")" = "$scope" ] && echo "$pid"
  done
}

pid_ganesha() { pgrep -x ganesha.nfsd 2>/dev/null | head -1; }

ticks() { [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
rss_kb() { [ -n "${1:-}" ] && awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }

scrape() { curl -sS -m 10 "$METRICS" -o "$1" 2>/dev/null; }

# The delta of one Prometheus counter between two scrapes.
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

# --- the mounts ----------------------------------------------------------

mount_arm() { # <arm>
  local arm=$1 d=$NM/$1
  sudo mkdir -p "$d"
  ( sudo umount -l "$d" >/dev/null 2>&1 ) &
  sleep 1
  sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
    "192.168.3.146:$(arm_pseudo "$arm")" "$d" >/dev/null 2>&1 \
    && echo "  mounted $arm -> $d" \
    || { echo "  MOUNT FAILED for $arm"; return 1; }
}

# --- one case ------------------------------------------------------------

run_case() { # <arm> <case> <bs> <size> <direct> <njobs> [fio args...]
  local arm=$1 label=$2 bs=$3 size=$4 direct=$5 nj=$6; shift 6
  local dir=$NM/$arm
  local jf=/tmp/ac-$arm-$label.fio
  local out=/tmp/ac-$arm-$label.out

  # --- the arm has to be healthy BEFORE the case ------------------------
  local sick
  sick=$(arm_health "$arm")
  if [ -n "$sick" ]; then
    printf '%-6s %-12s SKIPPED - the arm is not healthy:%s\n' "$arm" "$label" "$sick"
    echo "$arm,$label,,,,,,,,,,,,,,,,,,,,,,,,,0,0,skipped=1,unhealthy=1" >> "$CSV"
    return 0
  fi

  # --- and the host has to have room ------------------------------------
  local avail
  avail=$(mem_available_mb)
  if [ "${avail:-0}" -lt 4096 ]; then
    printf '  WARNING: only %s MiB available; giving the host 30 s to settle\n' "$avail"
    sleep 30
  fi

  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\nfallocate=none\n' \
           "$bs" "$direct" "$size"
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=ac-%s-%s.$jobnum\n' "$arm" "$label"
    # Non-zero data: SeaweedFS stores an all-zero chunk as a reference
    # only, so a zero-filled probe would not move the .dat size at all
    # and the landing check would be a false negative.
    printf 'scramble_buffers=1\n'
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in "$@"; do printf '%s\n' "$a"; done
  } > "$jf"

  local GP MP VP FP AP
  GP=$(pid_ganesha)
  MP=$(arm_pid "$arm" mount)
  VP=$(arm_pid "$arm" volume)
  FP=$(arm_pid "$arm" filer)
  AP=$(arm_pid "$arm" master)

  local g0 m0 v0 f0 a0 rg0 rm0 rv0 rf0 ra0 d0 t0
  g0=$(ticks $GP); m0=$(ticks $MP); v0=$(ticks $VP); f0=$(ticks $FP); a0=$(ticks $AP)
  rg0=$(rss_kb $GP); rm0=$(rss_kb $MP); rv0=$(rss_kb $VP); rf0=$(rss_kb $FP); ra0=$(rss_kb $AP)
  d0=$(arm_size "$arm")
  t0=$(date +%s.%N)
  scrape /tmp/ac-mb.txt

  timeout 900 "$FIO" "$jf" > "$out" 2>&1
  local rc=$?
  local t1=$(date +%s.%N)

  # Wait for the chunk upload to land.  A buffered write is uploaded
  # asynchronously, so the .dat size can keep moving after fio exits.
  local wait=0 stable=0 last=$(arm_size "$arm")
  while [ $wait -lt 40 ]; do
    sleep 1; wait=$((wait+1))
    local now=$(arm_size "$arm")
    if [ "$now" = "$last" ]; then stable=$((stable+1)); [ $stable -ge 3 ] && break; else stable=0; last=$now; fi
  done

  local g1 m1 v1 f1 a1 rg1 rm1 rv1 rf1 ra1 d1
  g1=$(ticks $GP); m1=$(ticks $MP); v1=$(ticks $VP); f1=$(ticks $FP); a1=$(ticks $AP)
  rg1=$(rss_kb $GP); rm1=$(rss_kb $MP); rv1=$(rss_kb $VP); rf1=$(rss_kb $FP); ra1=$(rss_kb $AP)
  d1=$(arm_size "$arm")
  scrape /tmp/ac-ma.txt

  # --- read the results -------------------------------------------------
  local bw clat cunit err iob mib
  bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' "$out" | tail -1 | cut -d= -f2)
  clat=$(fio_clat_ms "$out")
  cunit=ms
  err=$(grep -oE 'err= *[0-9]+' "$out" | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')
  iob=$(grep -oE 'io=[0-9.]+[KMG]iB' "$out" | tail -1 | cut -d= -f2)
  mib=0
  case "$iob" in
    *KiB) mib=$(awk -v x="${iob%KiB}" 'BEGIN{printf "%d", x/1024}') ;;
    *MiB) mib=$(awk -v x="${iob%MiB}" 'BEGIN{printf "%d", x}') ;;
    *GiB) mib=$(awk -v x="${iob%GiB}" 'BEGIN{printf "%d", x*1024}') ;;
  esac

  local wsum wcnt glat el landed
  wsum=$(mdelta /tmp/ac-mb.txt /tmp/ac-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  wcnt=$(mdelta /tmp/ac-mb.txt /tmp/ac-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  glat=0
  [ "$(awk -v c="$wcnt" 'BEGIN{print (c>0)?1:0}')" = "1" ] && \
    glat=$(awk -v s="$wsum" -v c="$wcnt" 'BEGIN{printf "%.3f", s/c}')
  el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
  landed=$(( (d1 - d0) / 1048576 ))

  # CPU seconds
  local cg cm cv cf ca ct gib pg
  cg=$(awk -v a=$g0 -v b=$g1 'BEGIN{printf "%.3f",(b-a)/100}')
  cm=$(awk -v a=$m0 -v b=$m1 'BEGIN{printf "%.3f",(b-a)/100}')
  cv=$(awk -v a=$v0 -v b=$v1 'BEGIN{printf "%.3f",(b-a)/100}')
  cf=$(awk -v a=$f0 -v b=$f1 'BEGIN{printf "%.3f",(b-a)/100}')
  ca=$(awk -v a=$a0 -v b=$a1 'BEGIN{printf "%.3f",(b-a)/100}')
  ct=$(awk -v g=$cg -v m=$cm -v v=$cv -v f=$cf -v a=$ca 'BEGIN{printf "%.3f", g+m+v+f+a}')
  gib=$(awk -v m=$mib 'BEGIN{printf "%.4f", m/1024}')
  pg=$(awk -v c=$ct -v g=$gib 'BEGIN{ if (g>0) printf "%.3f", c/g; else printf "0" }')

  # Sanity: CPU seconds cannot exceed elapsed * ncpu.
  local ncpu cpubad void
  ncpu=$(nproc)
  cpubad=0
  awk -v c="$ct" -v e="$el" -v n="$ncpu" 'BEGIN { exit (c > e*n) }' || cpubad=1
  # The case is void unless the bytes reached the volume server.
  void=0
  [ "$landed" -lt $((mib/2)) ] && void=1
  [ "$rc" != "0" ] && void=1
  [ "$err" != "0" ] && void=1

  printf '%-6s %-12s BW=%-9s clat=%-7s%s ganWlat=%-8s el=%-7ss wrote=%sMiB landed=%sMiB %s\n' \
    "$arm" "$label" "${bw:-0}" "${clat:-0}" "${cunit:-?}" "$glat" "$el" "$mib" "$landed" \
    "$([ "$void" -eq 1 ] && echo '*** VOID ***')"
  printf '        CPU-s: ganesha=%s mount=%s volume=%s filer=%s master=%s TOTAL=%s  CPU-s/GiB=%s  RSS(MB)=%s\n' \
    "$cg" "$cm" "$cv" "$cf" "$ca" "$ct" "$pg" \
    "$(awk -v a=$rg1 -v b=$rm1 -v c=$rv1 -v d=$rf1 -v e=$ra1 'BEGIN{printf "%.0f",(a+b+c+d+e)/1024}')"

  echo "$arm,$label,$bs,$nj,$direct,${bw:-0},${clat:-0},${cunit:-?},$glat,$el,$mib,$landed,$cg,$cm,$cv,$cf,$ca,$ct,$pg,$err,$rc,void=$void,cpubad=$cpubad" >> "$CSV"

  # clean up the test files
  for f in "$dir"/ac-"$arm"-"$label".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
  sleep 2

  # --- and it has to be healthy AFTER the case -------------------------
  # If a service died during the case, the next case against that arm
  # would hang the host.  Say so loudly and stop.
  sick=$(arm_health "$arm")
  if [ -n "$sick" ]; then
    printf '  *** %s DIED DURING THE CASE:%s\n' "$arm" "$sick"
    printf '  *** stopping the run: the host has to be recovered first\n'
    printf '  *** scripts/recover-fuse.sh, then scripts/docker-prepare-host.sh up\n'
    HOST_FAILED=1
    return 1
  fi
}

# --- the matrix ----------------------------------------------------------

echo "### arm comparison: $(date -Is) size=$SIZE rounds=$ROUNDS ###"
echo "arm,case,bs,njobs,direct,BW,clat_avg_ms,clat_unit,ganesha_wlat_ms,elapsed_s,wrote_mib,landed_mib,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,filer_cpu_s,master_cpu_s,total_cpu_s,total_per_gib,io_err,fio_rc,void,cpubad" > "$CSV"

# A leftover NFS client mount from an earlier run retries forever against
# this host's own NFS server.  Eleven of them were found on 2026-11-16 and
# they were part of what took the host to load 98.  Take them away before
# measuring anything.
echo "--- cleaning up leftover NFS client mounts of this host"
bash "$HERE/cleanup-stale-nfs-mounts.sh" | tail -3

sudo mkdir -p "$NM"
mount_failed=0
for arm in $ARMS; do mount_arm "$arm" || mount_failed=1; done
[ "$mount_failed" -eq 0 ] || { echo "ERROR: an arm did not mount; aborting"; exit 1; }

echo
echo "--- the arms, and where their bytes go ---"
for arm in $ARMS; do
  printf '  %-7s pseudo=%-20s master=%s volume=%s filer=%s mount=%s ganesha=%s\n' \
    "$arm" "$(arm_pseudo "$arm")" \
    "$(arm_pid "$arm" master)" "$(arm_pid "$arm" volume)" "$(arm_pid "$arm" filer)" \
    "$(arm_pid "$arm" mount)" "$(pid_ganesha)"
done

for r in $(seq 1 "$ROUNDS"); do
  [ "$HOST_FAILED" = "1" ] && break
  echo
  echo "######## round $r of $ROUNDS ########"
  # Rotate the order every round so every arm gets the same number of
  # first, middle and last positions.
  case $(( (r-1) % 3 )) in
    0) order="bare docker k8s" ;;
    1) order="docker k8s bare" ;;
    2) order="k8s bare docker" ;;
  esac
  echo "--- order: $order"

  for case in buf1M odirect1M odirect8M buf8job; do
    [ "$HOST_FAILED" = "1" ] && break
    echo
    echo "--- case $case"
    for arm in $order; do
      case "$case" in
        buf1M)     run_case "$arm" "$case" 1M "$SIZE" 0 1 end_fsync=1 ;;
        odirect1M) run_case "$arm" "$case" 1M "$SIZE" 1 1 ;;
        odirect8M) run_case "$arm" "$case" 8M "$SIZE" 1 1 ;;
        buf8job)   run_case "$arm" "$case" 1M "$CONC_SIZE" 0 8 end_fsync=1 ;;
      esac
      [ "$HOST_FAILED" = "1" ] && break
    done
  done
done

for arm in $ARMS; do ( sudo umount -l "$NM/$arm" >/dev/null 2>&1 ) & done
sleep 2
sudo rmdir "$NM" 2>/dev/null
rm -f /tmp/ac-*.fio /tmp/ac-*.out /tmp/ac-m*.txt
echo
echo "CSV: $CSV"
echo "done: $(date -Is)"
