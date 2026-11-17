#!/bin/bash
# =====================================================================
# k8s-fuse-fio.sh - the fourth shape: the FUSE gateway in a POD, fio in
# the same pod, writing straight into the Kubernetes storage plane.
#
#   usage: bash k8s-fuse-fio.sh [case ...]
#
# With no arguments the standard matrix runs: the same four cases the
# three-arm comparison uses, so the numbers can be put next to each other.
#
#   buf1M      1 MiB, buffered, one job
#   odirect1M  1 MiB, O_DIRECT, one job
#   odirect8M  8 MiB, O_DIRECT, one job
#   buf8job    1 MiB, buffered, eight jobs
#
# WHAT IT IS, AND WHAT IT IS NOT
#
#   fio -> FUSE (pod) -> filer (pod) -> volume server (pod)
#
# There is no NFS and no Ganesha in this path.  The other three arms
# measure "NFS client -> Ganesha -> FUSE -> filer -> volume"; this one
# measures the storage path on its own, from inside the cluster.  It is
# not a fourth point in the same series - it is the series without the
# NFS front end, which is what makes it useful: the difference between
# this and the Kubernetes arm of the three-arm comparison IS the cost of
# the NFS + Ganesha front end.
#
# WHY THE FUSE MOUNT CAN LIVE IN A POD HERE
#
# In the Docker arm the mount had to REACH THE HOST, because Ganesha runs
# on the host - and a mount created in a container does not propagate back
# to the host (it lands in another peer group).  Here the writer is in
# the same pod as the mount, so the mount never crosses a mount
# namespace at all.
#
# THE ADDRESSES
#
# The mount dials the filer at the LoadBalancer address and fetches the
# chunks from the address the master recorded for the volume server.
# Both are reachable from a pod (verified with k8s/net-probe.yaml).
#
# THE LANDING ASSERTION
#
# The pod that writes cannot see the volume server's data directory, so
# the .dat size is measured from the HOST, from inside the volume pod,
# before and after the case - the same way the Kubernetes arm of the
# three-arm comparison does it.  A case whose bytes did not land is void.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

LAB_ROOT=${LAB_ROOT:-/home/ys1000/seaweedfs}
MANIFEST=${MANIFEST:-$LAB_ROOT/k8s/40-fuse-fio.yaml}
NS=${K8S_NS:-seaweedfs}
IMAGE=${IMAGE:-seaweedfs-lab:4.54-fio}
FILER=${FILER:-172.18.255.52:19344}
JOB=${JOB:-seaweedfs-fuse-fio}
CSV=${CSV:-$LAB_ROOT/logs/k8s-fuse-fio.csv}
SIZE=${SIZE:-128M}
CONC_SIZE=${CONC_SIZE:-16M}
DATSIZE=${DATSIZE:-$LAB_ROOT/scripts/k8s-volume-datsize.sh}
# The host-side view of the SAME filer the pod writes to: the case's
# files are deleted through it, because the pod is gone by then.
MNT_K8S=${MNT_K8S:-$LAB_ROOT/mnt-k8s}
K8S_MASTER=${K8S_MASTER:-172.18.255.50:19340}
# Both timeouts scale with the case size: the 128 MiB-era 600/900 s pair
# is far too small for a 50 GiB case on a slow shape (the pod-side fio
# timeout is passed through the manifest into the pod).
JOB_WAIT=${JOB_WAIT:-900}
FIO_TIMEOUT=${FIO_TIMEOUT:-900}

KUBECTL=${KUBECTL:-kubectl}
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

# How many rounds to run.  One round is not enough: the same case measured
# twice on this host came out at 1143 MiB/s and 780 MiB/s, so the median
# of several rounds is the only number worth quoting.
ROUNDS=${ROUNDS:-3}

# The health of the storage plane the pod writes into.  A dead master or
# filer would make the mount hang and the host go with it, so the plane
# is checked before and after every case - the same discipline the
# three-arm comparison uses on the arms.
plane_health() {
  local role phase bad=""
  for role in master volume filer; do
    phase=$("$KUBECTL" -n "$NS" get pods -l "app=seaweedfs-$role" \
              -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null)
    if [ -z "$phase" ]; then
      bad="$bad $role:no-pod"
    else
      case "$phase" in
        *Running*) : ;;
        *) bad="$bad $role:$phase" ;;
      esac
    fi
  done
  # "the pod is Running" is not "the filer answers": a container can be
  # up while the process inside it is gone.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$FILER/" 2>/dev/null)
  case "$code" in
    2*|3*) : ;;
    *) bad="$bad filer(http ${code:-none})" ;;
  esac
  printf '%s' "$bad"
}

mem_available_mb() {
  awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# The case list lives at the bottom of this script, in the CASES array.
# It is built there because the size and the concurrency size are
# environment variables that are read before anything runs.

# case  bs   size      direct  niobs
if [ $# -gt 0 ]; then
  for c in "$@"; do
    case "$c" in
      buf1M|odirect1M|odirect8M|buf8job) : ;;
      *) echo "unknown case: $c" >&2; exit 2 ;;
    esac
  done
fi

# --- the image has to be in the node's containerd ------------------------
image_present() {
  local node img
  img=$1
  node=$("$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$node" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$node"; then
    docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  else
    sudo k3s ctr --namespace k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  fi
}

if ! image_present "$IMAGE"; then
  echo "=== the fio image is not in the node's containerd; building it ==="
  bash "$HERE/k8s-build-image.sh" "$IMAGE" --fio || exit 1
fi
image_present "$IMAGE" || { echo "ERROR: $IMAGE is not in the node's containerd" >&2; exit 1; }
echo "  ok     $IMAGE is in the node's containerd"

# --- the manifest --------------------------------------------------------
[ -f "$MANIFEST" ] || { echo "ERROR: $MANIFEST is not there" >&2; exit 2; }

run_case() { # <round> <case> <bs> <size> <direct> <njobs>
  local round=$1 case=$2 bs=$3 size=$4 direct=$5 nj=$6
  local yaml=/tmp/k8s-fuse-fio-job.yaml

  echo
  echo "--- round $round, case $case (bs=$bs size=$size direct=$direct numjobs=$nj)"

  # --- the plane has to be healthy BEFORE the case ------------------------
  local sick
  sick=$(plane_health)
  if [ -n "$sick" ]; then
    printf '  *** SKIPPED - the storage plane is not healthy:%s\n' "$sick"
    echo "$round,$case,$bs,$nj,$direct,,,,,,,void=1,0,skipped=1,unhealthy=1" >> "$CSV"
    return 2
  fi

  # --- and the host has to have room -------------------------------------
  # The write buffer is 4 GiB per mount and the host has 62 GiB with the
  # swap already full; a host that runs out of memory deadlocks the Go
  # scavenger against the FUSE write lock, which is what took the host
  # down on 2026-11-16.
  local avail
  avail=$(mem_available_mb)
  if [ "${avail:-0}" -lt 4096 ]; then
    printf '  WARNING: only %s MiB available; giving the host 30 s to settle\n' "$avail"
    sleep 30
  fi

  # The landing measurement has to start before the pod writes.
  local d0 d1 delta
  d0=$(bash "$DATSIZE")

  "$KUBECTL" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1
  sed -e "s|@FILER@|$FILER|g" \
      -e "s|@CASE@|$case|g" \
      -e "s|@BS@|$bs|g" \
      -e "s|@SIZE@|$size|g" \
      -e "s|@DIRECT@|$direct|g" \
      -e "s|@NJOBS@|$nj|g" \
      -e "s|@FIO_TIMEOUT@|$FIO_TIMEOUT|g" \
      "$MANIFEST" > "$yaml"

  "$KUBECTL" -n "$NS" apply -f "$yaml" >/dev/null 2>&1 || {
    echo "  ERROR: the job could not be created"; return 1; }

  if ! "$KUBECTL" -n "$NS" wait --for=condition=complete "job/$JOB" --timeout="${JOB_WAIT}s" >/dev/null 2>&1; then
    echo "  *** the job did not complete"
    "$KUBECTL" -n "$NS" get pods -l app=seaweedfs-fuse-fio -o wide 2>&1 | sed 's/^/  /'
    "$KUBECTL" -n "$NS" logs -l app=seaweedfs-fuse-fio --tail 40 2>&1 | sed 's/^/  /'
    return 1
  fi

  local logs result
  logs=$("$KUBECTL" -n "$NS" logs "job/$JOB" 2>&1)
  printf '%s\n' "$logs" | sed 's/^/  | /'
  result=$(printf '%s\n' "$logs" | grep -m1 '^RESULT ')
  [ -z "$result" ] && { echo "  *** the pod produced no RESULT line"; return 1; }

  # Wait for the chunk upload to land: a buffered write is uploaded
  # asynchronously, so the .dat size can keep moving after the pod exits.
  local wait=0 stable=0 last
  last=$(bash "$DATSIZE")
  while [ $wait -lt 60 ]; do
    sleep 2; wait=$((wait+2))
    local now=$(bash "$DATSIZE")
    if [ "$now" = "$last" ]; then stable=$((stable+1)); [ $stable -ge 3 ] && break; else stable=0; last=$now; fi
  done
  d1=$(bash "$DATSIZE")
  delta=$(( (d1 - d0) / 1048576 ))

  local bw clat cunit wrote elapsed
  # bw_agg is the GROUP aggregate: the pod selected it from fio's output
  # (the "WRITE: bw=" group line).  This script only reads the value.
  bw=$(printf '%s' "$result" | grep -oE 'bw_agg=[^ ]+' | cut -d= -f2)
  clat=$(printf '%s' "$result" | grep -oE 'clat=[^ ]+' | cut -d= -f2)
  cunit=$(printf '%s' "$result" | grep -oE 'cunit=[^ ]+' | cut -d= -f2)
  wrote=$(printf '%s' "$result" | grep -oE 'wrote_mib=[^ ]+' | cut -d= -f2)
  elapsed=$(printf '%s' "$result" | grep -oE 'elapsed=[^ ]+' | cut -d= -f2)

  local void=0
  [ "$delta" -lt "${wrote:-0}" ] && void=1

  printf '  %-12s BW=%-9s clat=%s%-4s el=%-7ss wrote=%sMiB landed=%sMiB %s\n' \
    "$case" "${bw:-0}" "${clat:-0}" "${cunit:-ms}" "$elapsed" "${wrote:-0}" "$delta" \
    "$([ "$void" -eq 1 ] && echo '*** VOID ***')"

  "$KUBECTL" -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null 2>&1

  # --- reclaim the space the case used ----------------------------------
  # The pod wrote into the filer's namespace and is gone now; the same
  # files are visible on the host mount of that filer.  Deleting them
  # there tombstones the chunks - the .dat only shrinks after a vacuum,
  # which must happen BETWEEN cases, never inside one (lib-nfslab.sh).
  # Without this, a sustained-size run fills the disk by the third case.
  rm -f "$MNT_K8S"/inpod-*-"$case".* 2>/dev/null
  local r0 r1 reclaim_s=0
  r0=$(date +%s)
  vacuum_cluster "$K8S_MASTER"
  wait_size_stable "bash $DATSIZE" 5 600 || true
  # The first vacuum can TRIGGER a compaction that outlives the settle
  # window (measured: .dat still 4.00 GiB after the first round, 0.00
  # after the second).  A second vacuum after the compaction had time to
  # finish is what actually returns the space - without it, four 50 GiB
  # cases stack towards the disk-filling regime.
  sleep 15
  vacuum_cluster "$K8S_MASTER"
  wait_size_stable "bash $DATSIZE" 5 600 || true
  r1=$(date +%s)
  reclaim_s=$((r1 - r0))
  printf '  reclaim: %ss, .dat now %s GiB\n' "$reclaim_s" \
    "$(awk -v b="$(bash "$DATSIZE")" 'BEGIN{printf "%.2f", b/1073741824}')"

  echo "$round,$case,$bs,$nj,$direct,${bw:-0},${clat:-0},${cunit:-ms},$elapsed,${wrote:-0},$delta,void=$void,$reclaim_s" >> "$CSV"

  # --- and the plane has to be healthy AFTER the case ---------------------
  # If a service died during the case, the next case would hang against a
  # half-dead cluster.  Say so loudly and stop.
  sick=$(plane_health)
  if [ -n "$sick" ]; then
    printf '  *** THE STORAGE PLANE DIED DURING THE CASE:%s\n' "$sick"
    printf '  *** stopping the run: the cluster has to be recovered first\n'
    PLANE_FAILED=1
    return 3
  fi
  return 0
}

echo "round,case,bs,njobs,direct,BW,clat_avg_ms,clat_unit,elapsed_s,wrote_mib,landed_mib,void,reclaim_s" > "$CSV"
echo "### the FUSE-in-a-pod arm: $(date -Is) rounds=$ROUNDS size=$SIZE ###"

# The cases run in a ROTATING order, one case per round shifted by one.
# The first case of a round is the one that pays for the page cache and
# the connection warm-up, so a fixed order would charge every round's
# first case with the same handicap - and the three-arm comparison does
# the same thing.
CASES=(
  "buf1M 1M $SIZE 0 1"
  "odirect1M 1M $SIZE 1 1"
  "odirect8M 8M $SIZE 1 1"
  "buf8job 1M $CONC_SIZE 0 8"
)
if [ $# -gt 0 ]; then
  CASES=()
  for c in "$@"; do
    case "$c" in
      buf1M)     CASES+=("buf1M 1M $SIZE 0 1") ;;
      odirect1M) CASES+=("odirect1M 1M $SIZE 1 1") ;;
      odirect8M) CASES+=("odirect8M 8M $SIZE 1 1") ;;
      buf8job)   CASES+=("buf8job 1M $CONC_SIZE 0 8") ;;
      *) echo "unknown case: $c" >&2; exit 2 ;;
    esac
  done
fi

PLANE_FAILED=0
n_cases=${#CASES[@]}
for ((r = 1; r <= ROUNDS; r++)); do
  for ((i = 0; i < n_cases; i++)); do
    idx=$(( (i + r - 1) % n_cases ))
    # shellcheck disable=SC2086
    set -- ${CASES[$idx]}
    run_case "$r" "$1" "$2" "$3" "$4" "$5"
    rc=$?
    # 2 = the plane was already sick, 3 = it died during the case.  Either
    # way there is nothing left to measure.
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
      PLANE_FAILED=1
      break
    fi
  done
  [ "$PLANE_FAILED" -eq 1 ] && break
done

echo
echo "CSV: $CSV"
if [ "$PLANE_FAILED" -eq 1 ]; then
  echo "*** the run stopped early: the storage plane died"
  exit 1
fi
echo "done: $(date -Is)"
