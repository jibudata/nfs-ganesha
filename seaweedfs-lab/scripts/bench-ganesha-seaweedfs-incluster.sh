#!/bin/bash
# =====================================================================
# bench-ganesha-seaweedfs-incluster.sh - fio INSIDE the cluster.
#
#   usage: bash bench-ganesha-seaweedfs-incluster.sh
#
# Measures the complete in-cluster path of the ganesha-seaweedfs stack:
#
#   fio pod -> NFSv4.1 ClusterIP -> Ganesha pod -> weed FUSE
#           -> filer -> volume -> master
#
# The client is a Job in the same namespace.  It mounts the export over
# the Ganesha Service (port 2049, no NodePort and no host route), writes
# with the pinned fio 3.36, and unmounts.  The host script measures the
# volume server's .dat growth around every case: a case is not valid
# until the bytes have landed (LAB-CONVENTIONS R4).
#
# This is a functional/local measurement, not a benchmark-farm claim.
# The Ganesha pod is limited to 4 CPUs and 8 GiB in this stack, and the
# kind node is shared; report the deployment shape with the numbers.
#
#   SIZE       per-job write size for the one-job cases (default 512M)
#   CONC_SIZE  per-job write size for the eight-job case (default 128M)
#   REPEAT     repeats per case (default 3); the summary prints medians
#   ARTIFACT_DIR  raw fio logs, job manifests and the CSV
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
NS=${K8S_NS:-ganesha-seaweedfs}
IMAGE=${FIO_IMAGE:-seaweedfs-lab:4.54-fio}
SVC=${GANESHA_SVC:-seaweedfs-ganesha-fuse}
SIZE=${SIZE:-512M}
CONC_SIZE=${CONC_SIZE:-128M}
REPEAT=${REPEAT:-3}
# Unique tag for this run's files and artifacts, so a rerun writes fresh
# files instead of overwriting the previous run's and skewing the case.
TAG=${TAG:-$(date +%Y%m%d-%H%M%S)}
FIO_TIMEOUT=${FIO_TIMEOUT:-1800}
LAND_WAIT=${LAND_WAIT:-300}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-seaweedfs-incluster}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

FAIL=0
say() { echo "$*"; }
ok()  { printf "  %-56s OK\n" "$1"; }
bad() { printf "  %-56s *** FAILED: %s\n" "$1" "$2"; FAIL=1; }

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi

node_name() { "$KUBECTL" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

image_present() { # <image>
  local img=$1 node
  node=$(node_name)
  [ -n "$node" ] || return 1
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$node"; then
    docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  elif command -v k3s >/dev/null 2>&1; then
    sudo k3s ctr --namespace k8s.io images ls -q 2>/dev/null | grep -qE "(^|/)$img$"
  else
    return 1
  fi
}

datsize() {
  K8S_NS="$NS" bash "$HERE/k8s-volume-datsize.sh"
}

# <volume-id>.dat <bytes>, one per line, from inside the volume pod.
# Comparing two snapshots shows WHICH SeaweedFS volumes a case wrote to,
# not just that the total grew.
volsizes() {
  "$KUBECTL" -n "$NS" exec statefulset/seaweedfs-volume -- sh -c \
    "find /data/vol -maxdepth 1 -name '*.dat' -printf '%f %s\n'" 2>/dev/null | sort
}

bytes_of() { numfmt --from=iec "$1"; }

pod_ready() { # <label-selector>
  [ "$("$KUBECTL" -n "$NS" get pods -l "$1" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

wait_job() { # <job> <seconds>; 0=complete, 1=failed, 2=timeout
  local job=$1 secs=$2 i=0 succ fail
  while [ "$i" -lt "$secs" ]; do
    succ=$("$KUBECTL" -n "$NS" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    fail=$("$KUBECTL" -n "$NS" get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null)
    case "$succ" in ''|*[!0-9]*) succ=0 ;; esac
    case "$fail" in ''|*[!0-9]*) fail=0 ;; esac
    [ "$succ" -ge 1 ] && return 0
    [ "$fail" -ge 1 ] && return 1
    sleep 2
    i=$((i + 2))
  done
  return 2
}

# --- preflight ------------------------------------------------------------

say "=== preflight ==="
command -v "$KUBECTL" >/dev/null 2>&1 || { say "ERROR: kubectl is not there"; exit 2; }
pod_ready app=seaweedfs-ganesha-fuse || {
  say "ERROR: the Ganesha/FUSE pod is not Ready; run k8s-ganesha-seaweedfs.sh up first"; exit 1; }
ok "the Ganesha/FUSE pod is Ready"

if image_present "$IMAGE"; then
  ok "$IMAGE is in the node's containerd"
else
  say "  $IMAGE is missing; building it (fio 3.36 + nfs-common)"
  bash "$HERE/k8s-build-image.sh" "$IMAGE" --fio || {
    say "ERROR: the fio image build failed"; exit 1; }
  image_present "$IMAGE" || { say "ERROR: $IMAGE is still not loaded"; exit 1; }
  ok "$IMAGE is in the node's containerd"
fi

mkdir -p "$ARTIFACT_DIR"
printf 'case,repeat,bw,clat_avg_ms,expected_bytes,landed_bytes,rc,volumes_touched,new_volumes\n' > "$CSV"

# --- one case -------------------------------------------------------------

run_case() { # <case> <bs> <direct> <jobs> <size> <repeat>
  local case_name=$1 bs=$2 direct=$3 jobs=$4 size=$5 rep=$6
  local run="${case_name}-r${rep}-${TAG}"
  local job jobfile log before after delta expected wait rc bw craw cunit clat
  local vbefore vafter vols newvols secs

  job="fio-${run}"
  jobfile="$ARTIFACT_DIR/${run}.job.yaml"
  log="$ARTIFACT_DIR/${run}.fio.log"
  vbefore="$ARTIFACT_DIR/${run}.volumes.before"
  vafter="$ARTIFACT_DIR/${run}.volumes.after"
  expected=$(( $(bytes_of "$size") * jobs ))
  before=$(datsize)
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  volsizes > "$vbefore"

  say ""
  say "=== $run: bs=$bs direct=$direct jobs=$jobs size/job=$size (expected $expected B) ==="

  # The first heredoc is expanded by this script (metadata and env); the
  # second is quoted so the pod's shell gets its own variables and the
  # inner fio heredoc intact.
  cat > "$jobfile" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NS
  labels:
    app: fio-ganesha-seaweedfs
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: fio-ganesha-seaweedfs
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 10
      containers:
        - name: fio
          image: $IMAGE
          imagePullPolicy: Never
          # mount(2) needs CAP_SYS_ADMIN; the client is privileged for
          # consistency with the FUSE arm.
          securityContext:
            privileged: true
          env:
            - name: CASE
              value: "$run"
            - name: BS
              value: "$bs"
            - name: DIRECT
              value: "$direct"
            - name: FSIZE
              value: "$size"
            - name: NJOBS
              value: "$jobs"
            - name: GANESHA_SVC
              value: "$SVC"
            - name: POD_NS
              value: "$NS"
            - name: FIO_TIMEOUT
              value: "$FIO_TIMEOUT"
          command:
            - /bin/bash
            - -ec
            - |
EOF
  cat >> "$jobfile" <<'POD'
              MNT=/mnt/nfs
              mkdir -p "$MNT"
              mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
                "$GANESHA_SVC.$POD_NS.svc.cluster.local:/seaweedfs" "$MNT"
              mounted=0
              for i in $(seq 1 30); do
                if awk -v m="$MNT" '$2 == m && $3 ~ /^nfs/ { f = 1 } END { exit !f }' /proc/mounts; then
                  mounted=1
                  break
                fi
                sleep 1
              done
              if [ "$mounted" != "1" ]; then
                echo "ERROR: the NFS mount did not appear at $MNT"
                exit 1
              fi
              mkdir -p "$MNT/data"
              JF=/tmp/job.fio
              cat > "$JF" <<JOB
              [global]
              ioengine=libaio
              rw=write
              bs=$BS
              direct=$DIRECT
              iodepth=16
              size=$FSIZE
              fallocate=none
              end_fsync=1
              scramble_buffers=1
              directory=$MNT/data
              filename_format=$CASE.\$jobnum
              group_reporting=1
              [$CASE]
              numjobs=$NJOBS
              JOB
              timeout "$FIO_TIMEOUT" /usr/bin/fio "$JF"
              rc=$?
              sync
              timeout 15 umount -l "$MNT" || true
              exit "$rc"
POD
  cat >> "$jobfile" <<EOF
          resources:
            requests:
              cpu: "1"
              memory: 512Mi
            limits:
              cpu: "8"
              memory: 2Gi
EOF

  "$KUBECTL" apply -f "$jobfile" >/dev/null || { bad "$run apply" "kubectl apply failed"; return 1; }
  secs=$((FIO_TIMEOUT + 180))
  if wait_job "$job" "$secs"; then
    rc=0
  else
    rc=$?
  fi
  "$KUBECTL" -n "$NS" logs "job/$job" > "$log" 2>&1 || true
  if [ "$rc" != "0" ]; then
    bad "$run" "the fio Job did not complete (state $rc); log: $log"
    "$KUBECTL" -n "$NS" describe job "$job" > "$ARTIFACT_DIR/${run}.describe.txt" 2>&1 || true
    tail -20 "$log" | sed 's/^/    /'
  fi

  # Group aggregate only: per-job lines come first, the "WRITE: bw=" line
  # is the group summary (R7).
  bw=$(grep -E '^[[:space:]]*WRITE:[[:space:]]*bw=' "$log" | tail -1 | sed -E 's/.*bw=([^, ]+).*/\1/')
  cunit=$(grep -oE 'clat \((msec|usec|nsec)\)' "$log" | head -1 | grep -oE '(msec|usec|nsec)')
  craw=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' "$log" \
         | grep -oE 'avg=[0-9.]+' | head -1 | cut -d= -f2)
  case "$cunit" in
    usec) clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x/1000}') ;;
    nsec) clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x/1000000}') ;;
    *)    clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x}') ;;
  esac
  [ -n "$bw" ] || bw=unknown

  # Landing check: wait for at least half of the expected bytes.  weed
  # buffers up to 4 GiB and uploads asynchronously, so the .dat keeps
  # moving after fio exits.
  after=$before
  wait=0
  while [ "$((after - before))" -lt "$((expected / 2))" ] && [ "$wait" -lt "$LAND_WAIT" ]; do
    sleep 2
    wait=$((wait + 2))
    after=$(datsize)
    case "$after" in ''|*[!0-9]*) after=$before ;; esac
  done
  delta=$((after - before))

  volsizes > "$vafter"
  vols=$(awk 'NR == FNR { b[$1] = $2; next } { if ($2 > (b[$1] + 0)) n++ } END { print n + 0 }' \
         "$vbefore" "$vafter")
  newvols=$(awk 'NR == FNR { seen[$1] = 1; next } !($1 in seen) { n++ } END { print n + 0 }' \
            "$vbefore" "$vafter")

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$case_name" "$rep" "$bw" "$clat" "$expected" "$delta" "$rc" "$vols" "$newvols" | tee -a "$CSV"
  if [ "$delta" -lt "$((expected / 2))" ]; then
    bad "$run landing" "only $delta bytes reached the volume .dat files"
  else
    ok "$run: bw=$bw clat=${clat}ms landed=${delta}B vols=$vols new=$newvols"
  fi

  "$KUBECTL" -n "$NS" delete job "$job" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# --- the matrix ------------------------------------------------------------

# Mirrors bench-k8s-ganesha-fuse.sh, but the client is in the cluster.
# Each case is repeated before moving to the next, so the repeats sit
# next to each other in the log and share the same backend state.
for rep in $(seq 1 "$REPEAT"); do
  run_case buffered-1m 1M 0 1 "$SIZE" "$rep"
done
for rep in $(seq 1 "$REPEAT"); do
  run_case odirect-1m 1M 1 1 "$SIZE" "$rep"
done
for rep in $(seq 1 "$REPEAT"); do
  run_case odirect-8m 8M 1 1 "$SIZE" "$rep"
done
for rep in $(seq 1 "$REPEAT"); do
  run_case buffered-8job 1M 0 8 "$CONC_SIZE" "$rep"
done

# --- summary ---------------------------------------------------------------

say ""
say "=== summary (median of $REPEAT repeats) ==="
printf '  %-16s %12s %14s\n' "case" "bw (MiB/s)" "clat (ms)"
for c in buffered-1m odirect-1m odirect-8m buffered-8job; do
  # Convert fio's unit-suffixed number to MiB/s before taking the median.
  mapfile -t bws < <(awk -F, -v c="$c" '
    NR > 1 && $1 == c {
      v = $3; gsub(/[A-Za-z\/]+/, "", v); v += 0
      if ($3 ~ /GiB\/s/) v *= 1024
      else if ($3 ~ /KiB\/s/) v /= 1024
      print v
    }' "$CSV" | grep -E '^[0-9.]+$' | sort -n)
  mapfile -t cls < <(awk -F, -v c="$c" 'NR > 1 && $1 == c && $4 ~ /^[0-9.]+$/ { print $4 }' "$CSV" | sort -n)
  if [ "${#bws[@]}" -eq 0 ]; then
    printf '  %-16s %12s %14s\n' "$c" "-" "-"
    continue
  fi
  bmed=$(printf '%s\n' "${bws[@]}" | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.1f", (a[NR/2]+a[NR/2+1])/2 }')
  cmed=$(printf '%s\n' "${cls[@]}" | awk '{a[NR]=$1} END { if (NR%2) print a[(NR+1)/2]; else printf "%.3f", (a[NR/2]+a[NR/2+1])/2 }')
  printf '  %-16s %12s %14s\n' "$c" "$bmed" "$cmed"
done

say ""
say "CSV: $CSV"
say "Raw fio logs and Job manifests: $ARTIFACT_DIR"
say "The written files remain under /data in the SeaweedFS export."
if [ "$FAIL" = "0" ]; then
  say "IN-CLUSTER FIO: PASS"
else
  say "IN-CLUSTER FIO: FAIL"
fi
exit "$FAIL"
