#!/bin/bash
# =====================================================================
# sustained-50g.sh - the SUSTAINED write matrix: 50 GiB per case, three
# arms, with the space reclaimed between cases.
#
#   usage:            bash sustained-50g.sh [case ...]
#   smoke:            SIZE=4G ARMS="bare" bash sustained-50g.sh buf_bs1M od_bs1M od_urand1M
#   full run:         SIZE=50G bash sustained-50g.sh
#   resume:           just run it again - cases already in the CSV with
#                     void=0 are skipped
#
# WHY THIS MATRIX EXISTS
#
# The three-arm comparison and the fourth shape were measured at 128 MiB
# per case, which the SeaweedFS write buffer (4 GiB) absorbs whole: those
# numbers are the acceptance rate of the buffer, not the throughput of
# the device behind it.  This harness writes 50 GiB per case - an order
# of magnitude past the buffer - so every case forces compaction, chunk
# rotation and real sustained landing, and asserts the landing per case
# like every other harness in this lab (R4/R4a).
#
# THE SPACE BUDGET (a hard cap, not a hope)
#
#   * every case writes at most $SIZE (default 50 GiB) TOTAL - with
#     numjobs>1 that is size-per-job x jobs, not per job;
#   * deleting a file through the mount only tombstones the chunks, the
#     .dat keeps its size: after EVERY case the arm's files are deleted,
#     the arm's master is vacuumed (compacted) and the .dat is verified
#     to be back at its baseline.  A reclaim that fails twice STOPS THE
#     RUN - a full disk wedges every cluster at once;
#   * the test-data footprint (sum over arms of .dat above baseline) is
#     checked before and after every case against CAP_MIB (default
#     100 GiB, per the run's space budget);
#   * free space on the volume-server filesystem is checked before every
#     case against MIN_FREE_MIB (default 120 GiB: one case of data, the
#     transient copy a compaction makes, and headroom).
#
# WHAT RUNS
#
# Per arm (bare, docker, k8s - the same three storage planes as
# arm-compare.sh, Ganesha and the FUSE gateway on the host in all three):
#
#   buf_bs<BS>    buffered, one fsync at the end (end_fsync=1)
#   od_bs<BS>     O_DIRECT (every NFS WRITE is stable -> a fsync each)
#   dsync_bs<BS>  buffered, fdatasync after every block (psync engine)
#                 for BS in 512k, 1M, 4M, 16M
#   buf_nf4       4 files, 4 writers, buffered + end fsync (12.5 GiB each)
#   buf_nf10      10 files, 10 writers, buffered + end fsync (5 GiB each)
#   od_nf10       10 files, 10 writers, O_DIRECT
#   od_urand1M    bare arm ONLY: the same shape as od_bs1M with the write
#                 buffer patterned from /dev/urandom, which answers "does
#                 the ORIGIN of the random bytes matter" as a controlled
#                 A/B - same engine, same iodepth, same file count, only
#                 the bytes differ.  This replaces an earlier dd-based
#                 spot check: dd is one file, one outstanding write, no
#                 iodepth, so its number measured the fully serialised
#                 stable-write path and compared with nothing.
#
# The cases run case-major (all arms per case, in the same order) so a
# drift in the machine's mood hits all three arms of a case alike.
#
# The fourth shape (FUSE + fio inside a pod, no NFS) is NOT run here:
# run k8s-fuse-fio.sh with the same SIZE once this finishes - both write
# the same Kubernetes cluster and must not overlap.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

CSV=${CSV:-/home/ys1000/seaweedfs/logs/sustained-50g.csv}
METRICS=${METRICS:-http://127.0.0.1:32000/metrics}
FIO=${FIO:-/usr/local/bin/fio}
SIZE=${SIZE:-50G}
ARMS=${ARMS:-"bare docker k8s"}
BS_LIST=${BS_LIST:-"512k 1M 4M 16M"}
NM=${NM:-/mnt/sus50g-$$}
K8S_DATSIZE=${K8S_DATSIZE:-/home/ys1000/seaweedfs/scripts/k8s-volume-datsize.sh}

# The space budget.  CAP_MIB bounds the test-data footprint (the sum over
# the arms of .dat bytes above the baseline); MIN_FREE_MIB bounds the
# free space the run is allowed to leave on the volume-server filesystem.
CAP_MIB=${CAP_MIB:-102400}
MIN_FREE_MIB=${MIN_FREE_MIB:-122880}

# One case may not run longer than this.  The slowest shape measured at
# 2 GiB (O_DIRECT, 512 KiB blocks) sustains ~66 MiB/s -> 50 GiB is ~13
# min; the timeout is that with 4x headroom, so a genuinely wedged path
# fails the case instead of hanging the run overnight.
CASE_TIMEOUT=${CASE_TIMEOUT:-3600}

# SIZE as fio takes it ("50G"), and the same in MiB for the arithmetic.
size_to_mib() {
  local s=$1 n u
  n=${s%%[GMgm]*}
  u=${s#$n}
  case "$u" in
    G*|g*) echo $((n * 1024)) ;;
    M*|m*) echo "$n" ;;
    *)     echo "$n" ;;
  esac
}
SIZE_MIB=$(size_to_mib "$SIZE")

HOST_FAILED=0

# --- per-arm facts (the same three storage planes as arm-compare.sh) -----

arm_pseudo() {
  case "$1" in
    bare)   echo "/seaweedfs" ;;
    docker) echo "/seaweedfs-docker" ;;
    k8s)    echo "/seaweedfs-k8s" ;;
  esac
}

arm_size() { # <arm> - .dat bytes of the arm's volume server
  case "$1" in
    bare)   vol_datsize /home/ys1000/seaweedfs/data ;;
    docker) vol_datsize /home/ys1000/seaweedfs/docker-data ;;
    k8s)    bash "$K8S_DATSIZE" ;;
  esac
}

arm_master() { # <arm> - the master to vacuum between cases
  case "$1" in
    bare)   echo "127.0.0.1:9333" ;;
    docker) echo "127.0.0.1:19340" ;;
    k8s)    echo "172.18.255.50:19340" ;;
  esac
}

arm_endpoints() {
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

arm_pid() { # <arm> <role> - same cgroup scoping as arm-compare.sh
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

mem_available_mb() {
  awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
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

# Free space, in MiB, of the filesystem the volume servers write to.
# stat -f on a LOCAL directory: never stat or df an NFS path (R2).
free_mib() {
  stat -f -c "%a %S" /home/ys1000/seaweedfs/data \
    | awk '{printf "%d", $1 * $2 / 1048576}'
}

# --- the space guards -----------------------------------------------------

BASE_bare=0 BASE_docker=0 BASE_k8s=0

record_baselines() {
  local arm
  for arm in $ARMS; do
    local v="BASE_$arm"
    eval "$v=\$(arm_size \"$arm\")"
    printf '  baseline %-7s %8.2f GiB\n' "$arm" \
      "$(awk -v b="${!v}" 'BEGIN{printf "%.2f", b/1073741824}')"
  done
}

# Test-data footprint: the sum over arms of .dat bytes ABOVE the baseline
# (clamped at zero per arm).  This is the number the space budget caps.
footprint_mib() {
  local arm cur basev base t=0
  for arm in $ARMS; do
    cur=$(arm_size "$arm")
    basev="BASE_$arm"; base=${!basev}
    t=$(awk -v a="$t" -v c="$cur" -v b="$base" \
        'BEGIN { d = (c - b) / 1048576; if (d < 0) d = 0; printf "%d", a + d }')
  done
  echo "$t"
}

# Reclaim an arm: delete its test files, vacuum its master, wait for the
# .dat to stop moving, and verify it is back at the baseline.  Echoes the
# seconds it took.  Returns 1 when the space did not come back.
reclaim_arm() { # <arm>
  local arm=$1 basev base now t0 t1
  basev="BASE_$arm"; base=${!basev}

  # The case's own files, deleted through the arm's NFS mount - the
  # filer entry goes now, the chunks are tombstoned asynchronously.
  rm -f "$NM/$arm"/sus-"$arm"-*.0 "$NM/$arm"/sus-"$arm"-ddurandom.bin 2>/dev/null
  sleep 5

  t0=$(date +%s)
  vacuum_cluster "$(arm_master "$arm")"
  # A slow compaction is not fatal; give it time to stop moving.
  wait_size_stable "arm_size $arm" 5 600 || true
  now=$(arm_size "$arm")
  if [ "$now" -le $((base + 2 * 1073741824)) ]; then
    t1=$(date +%s)
    echo $((t1 - t0))
    return 0
  fi
  # Some chunks were not yet tombstoned when the vacuum ran.  Give the
  # deletion another chance to propagate and compact again.
  printf '  reclaim: %s did not come back (%s -> %s, baseline %s); retrying\n' \
    "$arm" "$base" "$now" "$base" >&2
  sleep 30
  vacuum_cluster "$(arm_master "$arm")"
  wait_size_stable "arm_size $arm" 5 600 || true
  now=$(arm_size "$arm")
  t1=$(date +%s)
  [ "$now" -le $((base + 2 * 1073741824)) ] && { echo $((t1 - t0)); return 0; }
  echo $((t1 - t0))
  return 1
}

# The gate every case passes through BEFORE it is allowed to write.
space_guard() { # <arm> <case>
  local arm=$1 case=$2 fp fr
  fp=$(footprint_mib)
  if [ "$fp" -gt "$CAP_MIB" ]; then
    printf '  *** %s/%s: test-data footprint %s MiB exceeds the %s MiB cap\n' \
      "$arm" "$case" "$fp" "$CAP_MIB"
    return 1
  fi
  fr=$(free_mib)
  if [ "$fr" -lt "$MIN_FREE_MIB" ]; then
    printf '  *** %s/%s: only %s MiB free (need %s); reclaiming all arms once\n' \
      "$arm" "$case" "$fr" "$MIN_FREE_MIB"
    local a
    for a in $ARMS; do reclaim_arm "$a" >/dev/null || true; done
    fr=$(free_mib)
    if [ "$fr" -lt "$MIN_FREE_MIB" ]; then
      printf '  *** still only %s MiB free - stopping\n' "$fr"
      return 1
    fi
  fi
  return 0
}

# --- resume: a case already in the CSV with void=0 is not run again ------

case_done() { # <arm> <case>
  [ -f "$CSV" ] && awk -F, -v a="$1" -v c="$2" \
    '$1 == a && $2 == c && $22 == "void=0" { found = 1 } END { exit !found }' "$CSV"
}

# --- one fio case ----------------------------------------------------------

# run_case <arm> <case> <bs> <mode> <per-job-size> <njobs> [fio opts...]
#   mode od    -> O_DIRECT, libaio, iodepth 16
#   mode buf   -> buffered, one fsync at the end
#   mode dsync -> buffered, fdatasync per block, psync engine
# Extra fio options are appended one per line (fio takes one option per
# line - a space-joined string would be a single bad option).
run_case() {
  local arm=$1 label=$2 bs=$3 mode=$4 size=$5 nj=$6; shift 6
  local dir=$NM/$arm
  local jf=/tmp/sus-$arm-$label.fio
  local out=/tmp/sus-$arm-$label.out
  local engine=libaio
  local extra=()

  case "$mode" in
    buf)   extra+=(end_fsync=1) ;;
    dsync) engine=psync; extra+=(fdatasync=1) ;;
  esac
  extra+=("$@")

  local sick
  sick=$(arm_health "$arm")
  if [ -n "$sick" ]; then
    printf '%-7s %-14s SKIPPED - the arm is not healthy:%s\n' "$arm" "$label" "$sick"
    echo "$arm,$label,$bs,$mode,$nj,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,void=1,0,skipped=1" >> "$CSV"
    return 0
  fi
  space_guard "$arm" "$label" || { HOST_FAILED=1; return 1; }

  local avail
  avail=$(mem_available_mb)
  if [ "${avail:-0}" -lt 4096 ]; then
    printf '  WARNING: only %s MiB available; giving the host 30 s to settle\n' "$avail"
    sleep 30
  fi

  {
    printf '[global]\n'
    printf 'ioengine=%s\nrw=write\nbs=%s\niodepth=%s\n' \
           "$engine" "$bs" "$([ "$engine" = libaio ] && echo 16 || echo 1)"
    printf 'direct=%s\n' "$([ "$mode" = od ] && echo 1 || echo 0)"
    printf 'size=%s\nfallocate=none\n' "$size"
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=sus-%s-%s.$jobnum\n' "$arm" "$label"
    # Non-zero data: SeaweedFS stores an all-zero chunk as a reference
    # only, so a zero-filled write would not move the .dat at all and the
    # landing check would be a false negative (R4a).
    printf 'scramble_buffers=1\n'
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    [ ${#extra[@]} -gt 0 ] && printf '%s\n' "${extra[@]}"
  } > "$jf"

  local GP MP VP FP AP g0 m0 v0 f0 a0 d0 t0
  GP=$(pid_ganesha)
  MP=$(arm_pid "$arm" mount)
  VP=$(arm_pid "$arm" volume)
  FP=$(arm_pid "$arm" filer)
  AP=$(arm_pid "$arm" master)
  g0=$(ticks $GP); m0=$(ticks $MP); v0=$(ticks $VP); f0=$(ticks $FP); a0=$(ticks $AP)
  d0=$(arm_size "$arm")
  t0=$(date +%s.%N)
  scrape /tmp/sus-mb.txt

  timeout "$CASE_TIMEOUT" "$FIO" "$jf" > "$out" 2>&1
  local rc=$?
  local t1=$(date +%s.%N)

  # Wait for the chunk upload to land: a buffered write is uploaded
  # asynchronously, so the .dat can keep moving after fio exits.
  wait_size_stable "arm_size $arm" 5 180 || true

  local g1 m1 v1 f1 a1 d1
  g1=$(ticks $GP); m1=$(ticks $MP); v1=$(ticks $VP); f1=$(ticks $FP); a1=$(ticks $AP)
  d1=$(arm_size "$arm")
  scrape /tmp/sus-ma.txt

  local bw clat err iob mib
  bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' "$out" | tail -1 | cut -d= -f2)
  clat=$(fio_clat_ms "$out")
  err=$(grep -oE 'err= *[0-9]+' "$out" | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')
  iob=$(grep -oE 'io=[0-9.]+[KMG]iB' "$out" | tail -1 | cut -d= -f2)
  mib=0
  case "$iob" in
    *KiB) mib=$(awk -v x="${iob%KiB}" 'BEGIN{printf "%d", x/1024}') ;;
    *MiB) mib=$(awk -v x="${iob%MiB}" 'BEGIN{printf "%d", x}') ;;
    *GiB) mib=$(awk -v x="${iob%GiB}" 'BEGIN{printf "%d", x*1024}') ;;
  esac

  local wsum wcnt glat el landed
  wsum=$(mdelta /tmp/sus-mb.txt /tmp/sus-ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  wcnt=$(mdelta /tmp/sus-mb.txt /tmp/sus-ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  glat=0
  [ "$(awk -v c="$wcnt" 'BEGIN{print (c>0)?1:0}')" = "1" ] && \
    glat=$(awk -v s="$wsum" -v c="$wcnt" 'BEGIN{printf "%.3f", s/c}')
  el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
  landed=$(( (d1 - d0) / 1048576 ))

  local cg cm cv cf ca ct gib
  cg=$(awk -v a=$g0 -v b=$g1 'BEGIN{printf "%.3f",(b-a)/100}')
  cm=$(awk -v a=$m0 -v b=$m1 'BEGIN{printf "%.3f",(b-a)/100}')
  cv=$(awk -v a=$v0 -v b=$v1 'BEGIN{printf "%.3f",(b-a)/100}')
  cf=$(awk -v a=$f0 -v b=$f1 'BEGIN{printf "%.3f",(b-a)/100}')
  ca=$(awk -v a=$a0 -v b=$a1 'BEGIN{printf "%.3f",(b-a)/100}')
  ct=$(awk -v g=$cg -v m=$cm -v v=$cv -v f=$cf -v a=$ca 'BEGIN{printf "%.3f", g+m+v+f+a}')

  # Sanity: CPU seconds cannot exceed elapsed * ncpu (R9).
  local ncpu cpubad void
  ncpu=$(nproc)
  cpubad=0
  awk -v c="$ct" -v e="$el" -v n="$ncpu" 'BEGIN { exit (c > e*n) }' || cpubad=1
  # The case is void unless the bytes reached the volume server (R4).
  void=0
  [ "$landed" -lt $((mib/2)) ] && void=1
  [ "$rc" != "0" ] && void=1
  [ "$err" != "0" ] && void=1

  printf '%-7s %-14s BW=%-10s clat=%-9sms ganWlat=%-8s el=%-8ss wrote=%sMiB landed=%sMiB %s\n' \
    "$arm" "$label" "${bw:-0}" "${clat:-0}" "$glat" "$el" "$mib" "$landed" \
    "$([ "$void" -eq 1 ] && echo '*** VOID ***')"

  # Reclaim BEFORE the row is written: reclaim_s and the post-reclaim
  # .dat are part of the record, and a failed reclaim stops the run.
  local rcs
  rcs=$(reclaim_arm "$arm") || {
    printf '  *** %s: RECLAIM FAILED - the space did not come back\n' "$arm"
    printf '  *** stopping the run: a full disk wedges every cluster at once\n'
    echo "$arm,$label,$bs,$mode,$nj,${bw:-0},${clat:-0},$glat,$el,$mib,$landed,$cg,$cm,$cv,$cf,$ca,$ct,$err,$rc,$rcs,0,void=$void,cpubad=$cpubad,reclaim_failed=1" >> "$CSV"
    HOST_FAILED=1
    rm -f "$jf"
    return 1
  }
  local basev after
  basev="BASE_$arm"
  after=$(( ($(arm_size "$arm") - ${!basev}) / 1048576 ))
  printf '        reclaim=%ss  footprint_now=%sMiB  cpu_s g/m/v/f/m=%s/%s/%s/%s/%s\n' \
    "$rcs" "$(footprint_mib)" "$cg" "$cm" "$cv" "$cf" "$ca"

  echo "$arm,$label,$bs,$mode,$nj,${bw:-0},${clat:-0},$glat,$el,$mib,$landed,$cg,$cm,$cv,$cf,$ca,$ct,$err,$rc,$rcs,$after,void=$void,cpubad=$cpubad" >> "$CSV"

  rm -f "$jf"

  sick=$(arm_health "$arm")
  if [ -n "$sick" ]; then
    printf '  *** %s DIED DURING THE CASE:%s\n' "$arm" "$sick"
    printf '  *** stopping the run: the host has to be recovered first\n'
    HOST_FAILED=1
    return 1
  fi
}

# --- the matrix ------------------------------------------------------------

# Case order: buf_bs1M first (fast, catches a broken harness in a minute),
# then the sweep, then the concurrency shapes, then the dd spot check.
MATRIX=""
add() { local a; for a in "$@"; do MATRIX="$MATRIX $a"; done; }
add buf_bs1M
for bs in $BS_LIST; do
  case $bs in 1M) continue ;; esac
  add buf_bs$bs
done
for bs in $BS_LIST; do add od_bs$bs; done
for bs in $BS_LIST; do add dsync_bs$bs; done
add buf_nf4 buf_nf10 od_nf10 od_urand1M

# Optional argv filters the case list (for smoke runs).
if [ $# -gt 0 ]; then
  local_matrix=""
  # shellcheck disable=SC2086
  for c in $MATRIX; do
    for want in "$@"; do
      [ "$c" = "$want" ] && local_matrix="$local_matrix $c"
    done
  done
  MATRIX="${local_matrix# }"
  [ -n "$MATRIX" ] || { echo "no requested case is in the matrix" >&2; exit 2; }
fi

per_job() { # <njobs> - the fio per-job size that makes the case total SIZE
  echo "$((SIZE_MIB / $1))M"
}

# --- setup ------------------------------------------------------------------

echo "### sustained matrix: $(date -Is) size=$SIZE (${SIZE_MIB} MiB) arms='$ARMS' ###"
echo "### cap=${CAP_MIB} MiB test data, min free=${MIN_FREE_MIB} MiB, case timeout=${CASE_TIMEOUT}s ###"

if [ ! -f "$CSV" ]; then
  echo "arm,case,bs,mode,njobs,BW,clat_avg_ms,ganesha_wlat_ms,elapsed_s,wrote_mib,landed_mib,ganesha_cpu_s,mount_cpu_s,volume_cpu_s,filer_cpu_s,master_cpu_s,total_cpu_s,io_err,fio_rc,reclaim_s,dat_after_mib,void,cpubad" > "$CSV"
else
  echo "--- resuming: $(grep -c . "$CSV") rows already in $CSV"
fi

# A leftover NFS client mount from an earlier run retries forever against
# this host's own NFS server and can take the host to load 98 (it did on
# 2026-11-16).  Take them away before measuring anything.
echo "--- cleaning up leftover NFS client mounts of this host"
bash "$HERE/cleanup-stale-nfs-mounts.sh" | tail -3

# Start from a known floor: compact every arm once, so the baselines the
# space budget measures from are the real floor and not last week's
# garbage (the pre-run sweep of 2026-11-17 reclaimed 10.4/3.7/7.1 GiB).
echo "--- pre-run vacuum of every arm (between cases only - never inside one)"
for arm in $ARMS; do
  vacuum_cluster "$(arm_master "$arm")"
  wait_size_stable "arm_size $arm" 5 300 || true
  printf '  %-7s vacuumed, .dat at %s GiB\n' \
    "$arm" "$(awk -v b="$(arm_size "$arm")" 'BEGIN{printf "%.2f", b/1073741824}')"
done

# The kernel-urandom pattern for the od_urand1M control case, as fio
# takes it: "0x" + hex, which fio 3.36 cycles across the buffer.  Two
# traps measured here: buffer_pattern does NOT take a file path ("failed
# parsing"), and the \xNN escape form is rejected too - only the 0x-hex
# form parses, and it caps out between 1024 and 4096 bytes of pattern
# (fio's option line is too short for more).  1024 bytes of urandom is
# plenty: the control varies the ORIGIN of the bytes, not their volume.
# The hex is saved next to the CSV so the run stays reproducible.
# /dev/urandom, never /dev/zero: a zero pattern would be stored as chunk
# references and silently void the landing check (R4a).
URAND_HEX=$(head -c 1024 /dev/urandom | xxd -p | tr -d '\n')
URAND_HEX_FILE=${URAND_HEX_FILE:-$(dirname "$CSV")/urand-pattern.hex}
mkdir -p "$(dirname "$URAND_HEX_FILE")"
printf '0x%s\n' "$URAND_HEX" > "$URAND_HEX_FILE"

record_baselines

mount_failed=0
sudo mkdir -p "$NM"
for arm in $ARMS; do
  d=$NM/$arm
  sudo mkdir -p "$d"
  ( sudo umount -l "$d" >/dev/null 2>&1 ) &
  sleep 1
  if sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$(arm_pseudo "$arm")" "$d" >/dev/null 2>&1; then
    echo "  mounted $arm -> $d"
  else
    echo "  MOUNT FAILED for $arm"
    mount_failed=1
  fi
done
[ "$mount_failed" -eq 0 ] || { echo "ERROR: an arm did not mount; aborting"; exit 1; }

cleanup_mounts() {
  local arm
  for arm in $ARMS; do ( sudo umount -l "$NM/$arm" >/dev/null 2>&1 ) & done
  sleep 2
  sudo rmdir "$NM"/* "$NM" 2>/dev/null
  rm -f /tmp/sus-*.fio /tmp/sus-*.out /tmp/sus-m*.txt
}
trap cleanup_mounts EXIT

echo
echo "--- the arms, and where their bytes go ---"
for arm in $ARMS; do
  printf '  %-7s pseudo=%-20s master=%s volume=%s filer=%s mount=%s ganesha=%s\n' \
    "$arm" "$(arm_pseudo "$arm")" \
    "$(arm_pid "$arm" master)" "$(arm_pid "$arm" volume)" "$(arm_pid "$arm" filer)" \
    "$(arm_pid "$arm" mount)" "$(pid_ganesha)"
done

# --- run: case-major, all arms per case --------------------------------------

for c in $MATRIX; do
  [ "$HOST_FAILED" = "1" ] && break
  echo
  echo "======== case $c ========"
  for arm in $ARMS; do
    [ "$HOST_FAILED" = "1" ] && break
    if case_done "$arm" "$c"; then
      printf '%-7s %-14s already done (void=0 in the CSV) - skipped\n' "$arm" "$c"
      continue
    fi
    case "$c" in
      buf_bs1M|buf_bs512k|buf_bs4M|buf_bs16M)
        run_case "$arm" "$c" "${c#buf_bs}" buf "$SIZE" 1 ;;
      od_bs512k|od_bs1M|od_bs4M|od_bs16M)
        run_case "$arm" "$c" "${c#od_bs}" od "$SIZE" 1 ;;
      dsync_bs512k|dsync_bs1M|dsync_bs4M|dsync_bs16M)
        run_case "$arm" "$c" "${c#dsync_bs}" dsync "$SIZE" 1 ;;
      buf_nf4)  run_case "$arm" "$c" 1M buf "$(per_job 4)" 4 ;;
      buf_nf10) run_case "$arm" "$c" 1M buf "$(per_job 10)" 10 ;;
      od_nf10)  run_case "$arm" "$c" 1M od "$(per_job 10)" 10 ;;
      od_urand1M)
        # The content-origin control runs on the bare arm only: all
        # three arms run the same SeaweedFS code, so content sensitivity
        # would not differ per arm.
        if [ "$arm" = bare ]; then
          run_case "$arm" "$c" 1M od "$SIZE" 1 "buffer_pattern=0x$URAND_HEX"
        else
          printf '%-7s %-14s bare-only control - not run on %s\n' "$arm" "$c" "$arm"
        fi ;;
      *) echo "unknown case $c" >&2 ;;
    esac
  done
done

echo
echo "footprint at end: $(footprint_mib) MiB above baseline"
echo "CSV: $CSV"
if [ "$HOST_FAILED" = "1" ]; then
  echo "*** the run stopped early - see the last *** line above"
  exit 1
fi
echo "done: $(date -Is)"
