#!/bin/bash
# =====================================================================
# bench-chunk-size.sh - small/random write vs weed chunk size
#
# Varies ONLY CHUNK_SIZE_LIMIT_MB on the Ganesha/FUSE deployment and
# reruns the small-write cases on a 10 GiB dataset:
#
#   * seq-write-4k-overwrite  existing chunks -> SIZE/chunk RMW
#   * seq-write-4k-append     1 GiB file, file_append=1 -> no RMW
#   * rand-write-4k           existing chunks -> chunk RMW
#   * rand-write-64k          existing chunks -> chunk RMW
#
# Everything is 60 s time_based, O_DIRECT, end_fsync=1, auto tier.
# The dataset is rebuilt after each pod restart because the chunk size is
# baked into the weed mount at start time.  Files are deleted, the pool
# is vacuumed after a 130 s FUSE delete-flush wait, then the next chunk
# size is tested.  The deployment is restored to CHUNK=8 at the end.
#
#   usage: bash bench-chunk-size.sh [repeat]
#   env:   SIZE (default 10G), CHUNKS (default "8 4 2"), CASES
#
# Artifacts: /tmp/ganesha-chunk-size/ (fio jobs, logs, CSV)
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

MNT=${POD_MNT:-/mnt/ganesha-seaweedfs}
DATA=$MNT/data
NODE_IP=${NODE_IP:-172.18.0.2}
NFS_PORT=${NFS_PORT:-32049}
NFS_OPTS=${NFS_OPTS:-"vers=4.1,proto=tcp,port=$NFS_PORT,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2"}
REPEAT=${1:-${REPEAT:-3}}
SIZE=${SIZE:-10G}
APPEND_SIZE=${APPEND_SIZE:-1G}
CHUNKS=${CHUNKS:-"8 4 2"}
CASES=${CASES:-all}
FIO=${FIO:-$(command -v fio || echo /usr/local/bin/fio)}
TIMEOUT=${TIMEOUT:-1800}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-chunk-size}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}
NS=${K8S_NS:-ganesha-seaweedfs}
FLUSH_WAIT=${FLUSH_WAIT:-130}
DEPLOY=${DEPLOY:-seaweedfs-ganesha-fuse}

mkdir -p "$ARTIFACT_DIR"
[ -f "$CSV" ] || printf 'chunk,case,rw,bs,direct,repeat,bw,iops,clat_ms,laying_out,rc\n' > "$CSV"

say() { echo "$*"; }
bad() { echo "  *** FAILED: $*" >&2; }
want() { [ "$CASES" = all ] && return 0; case " $CASES " in *" $1 "*) return 0 ;; esac; return 1; }
DS=$DATA/cs-data.0
AP=$DATA/cs-append.0

remount() {
  sudo umount -l "$MNT" 2>/dev/null || true
  sudo mount -t nfs -o "$NFS_OPTS" "$NODE_IP:/seaweedfs" "$MNT" || { echo "ERROR: mount failed" >&2; return 1; }
  is_mounted "$MNT" || { echo "ERROR: mount not visible" >&2; return 1; }
  say "--- mount: async ($NFS_OPTS)"
}

datsize() { kubectl -n "$NS" exec seaweedfs-volume-0 -- du -sb /data/vol 2>/dev/null | cut -f1; }

vacuum() {
  local prev=-1 cur i
  say "--- delete flush wait ${FLUSH_WAIT}s, then vacuum"
  sleep "$FLUSH_WAIT"
  printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
    kubectl -n "$NS" exec -i deploy/seaweedfs-master -- \
      /usr/local/bin/weed shell -master=127.0.0.1:9333 >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    cur=$(datsize); case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    say "    .dat $(awk -v x="$cur" 'BEGIN{printf "%.1f GiB", x/1073741824}')"
    [ "$cur" -eq "$prev" ] && break
    prev=$cur
    sleep 15
  done
}

chunk_env() {
  kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHUNK_SIZE_LIMIT_MB")].value}' 2>/dev/null
}

set_chunk() { # <mb>
  local mb=$1 cur got
  cur=$(chunk_env)
  if [ "$cur" != "$mb" ]; then
    say "=== set CHUNK_SIZE_LIMIT_MB=$mb (was ${cur:-unset}) ==="
    kubectl -n "$NS" set env "deploy/$DEPLOY" CHUNK_SIZE_LIMIT_MB="$mb" >/dev/null \
      || { bad "set env failed"; exit 1; }
    kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s || exit 1
    sleep 2
    remount || exit 1
  else
    say "=== CHUNK_SIZE_LIMIT_MB=$mb (already set) ==="
    is_mounted "$MNT" || { remount || exit 1; }
  fi
  got=$(kubectl -n "$NS" exec "deploy/$DEPLOY" -- sh -c 'ps -ef | grep "weed mount" | grep -v grep' 2>/dev/null \
        | grep -oE -- '-chunkSizeLimitMB=[0-9]+' | cut -d= -f2)
  say "    weed mount chunkSizeLimitMB=${got:-?}"
  [ "$got" = "$mb" ] || { bad "chunk size mismatch (got ${got:-?}, want $mb)"; exit 1; }
}

prep_dataset() {
  rm -f "$DS"
  local job="$ARTIFACT_DIR/prep-$SIZE.fio" log="$ARTIFACT_DIR/prep-$SIZE.log"
  cat > "$job" <<EOF
[global]
ioengine=libaio
rw=write
bs=1M
direct=0
iodepth=16
size=$SIZE
filename=$DS
fallocate=none
end_fsync=1
scramble_buffers=1
group_reporting=1

[prep]
EOF
  say "=== dataset $SIZE ==="
  timeout 900 "$FIO" "$job" > "$log" 2>&1 || bad "prep rc=$? ($log)"
}

prep_append() {
  rm -f "$AP"
  truncate -s "$APPEND_SIZE" "$AP" || { bad "truncate $AP failed"; exit 1; }
  say "=== append base $APPEND_SIZE (size=$(stat -c %s "$AP" 2>/dev/null)) ==="
}

run_case() { # <name> <rw> <bs> <qd> <runtime> <ds|append> <file_append 0|1>
  local name=$1 rw=$2 bs=$3 qd=$4 runtime=$5 src=$6 fa=$7
  local job="$ARTIFACT_DIR/${CHUNK}-${name}-r${REP}.fio"
  local log="$ARTIFACT_DIR/${CHUNK}-${name}-r${REP}.log"
  local fp=$DS
  [ "$src" = append ] && fp=$AP

  cat > "$job" <<EOF
[global]
ioengine=libaio
rw=$rw
bs=$bs
direct=1
iodepth=$qd
numjobs=1
size=$([ "$src" = append ] && echo "$APPEND_SIZE" || echo "$SIZE")
filename=$fp
fallocate=none
scramble_buffers=1
group_reporting=1
time_based=1
runtime=$runtime
end_fsync=1
EOF
  [ "$fa" = 1 ] && echo "file_append=1" >> "$job"
  printf '\n[%s]\n' "$name" >> "$job"

  say "=== [chunk $CHUNK] $name run $REP/$REPEAT (rw=$rw bs=$bs qd=$qd append=$fa) ==="
  timeout "$TIMEOUT" "$FIO" "$job" > "$log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || bad "$name rc=$rc; see $log"

  local bw iops cunit craw clat layout
  bw=$(grep -E '^[[:space:]]*(READ|WRITE):[[:space:]]*bw=' "$log" | tail -1 | sed -E 's/.*bw=([^, ]+).*/\1/')
  [ -n "$bw" ] || bw=unknown
  iops=$(grep -oE 'IOPS=[0-9.]+[kKmM]?' "$log" | head -1 | cut -d= -f2)
  [ -n "$iops" ] || iops=0
  cunit=$(grep -oE 'clat \((msec|usec|nsec)\)' "$log" | head -1 | grep -oE '(msec|usec|nsec)')
  craw=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' "$log" | grep -oE 'avg=[0-9.]+' | head -1 | cut -d= -f2)
  case "$cunit" in
    usec) clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x/1000}') ;;
    nsec) clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x/1000000}') ;;
    *)    clat=$(awk -v x="${craw:-0}" 'BEGIN{printf "%.3f", x}') ;;
  esac
  layout=$(grep -q "Laying out" "$log" && echo yes || echo no)

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$CHUNK" "$name" "$rw" "$bs" "1" "$REP" "$bw" "$iops" "$clat" "$layout" "$rc" >> "$CSV"
  say "  bw=$bw iops=$iops clat=${clat}ms layout=$layout rc=$rc"
}

RESTORED=0
restore_original() {
  [ "$RESTORED" = 1 ] && return
  kubectl -n "$NS" set env "deploy/$DEPLOY" CHUNK_SIZE_LIMIT_MB=8 >/dev/null 2>&1 || true
  kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s >/dev/null 2>&1 || true
  remount >/dev/null 2>&1 || true
}
trap restore_original EXIT

for CHUNK in $CHUNKS; do
  set_chunk "$CHUNK"
  prep_dataset
  prep_append
  for REP in $(seq 1 "$REPEAT"); do
    want seq-write-4k-overwrite && run_case seq-write-4k-overwrite write     4k 32 60 ds     0
    want seq-write-4k-append    && run_case seq-write-4k-append    write     4k 32 60 append 1
    want rand-write-4k          && run_case rand-write-4k          randwrite 4k 32 60 ds     0
    want rand-write-64k         && run_case rand-write-64k         randwrite 64k 32 60 ds    0
  done
  rm -f "$DS" "$AP"
  sync
  vacuum
done

set_chunk 8
RESTORED=1
rm -f "$DS" "$AP"
sync
say ""
say "CSV: $CSV"
say "NOTE: restored CHUNK_SIZE_LIMIT_MB=8; final vacuum state above."
