#!/bin/bash
# =====================================================================
# bench-mount-sync.sh - NFS client mount "sync" vs default "async"
#
# The rest of the lab fixes the backend (auto tier) and the fio
# parameters; this script changes ONLY the NFS client mount option and
# reruns every write case from the main matrix on a 10 GiB dataset
# (>2 of the 4 GiB SeaweedFS volumes):
#
#   * seq-write-1m-buf    fio buffered  (direct=0)  <- largest effect
#   * seq-write-4m-dir    fio O_DIRECT  (direct=1)
#   * seq-write-8m-dir    fio O_DIRECT  (direct=1)
#   * seq-write-4k-dir    O_DIRECT, 60 s overwrite
#   * rand-write-4k-dir   O_DIRECT, 60 s overwrite
#   * rand-write-64k-dir  O_DIRECT, 60 s overwrite
#   * rand-write-1m-dir   O_DIRECT, 60 s overwrite
#
# "sync" is the mount option (per-write NFS commit), not fio fsync=1 and
# not the SeaweedFS fsync storage rule.  All write cases still use
# end_fsync=1, matching the main matrix.
#
# The seq cases write SIZE bytes each rep; the 4K/random cases are
# time_based (60 s) on the same SIZE dataset, as in the main matrix.
# Files are deleted after each rep and the pool is vacuumed between
# mount modes after a 130 s FUSE delete-flush wait.
#
#   usage: bash bench-mount-sync.sh [repeat]
#   env:   SIZE (default 10G), CASES (filter), MODES (default "async sync")
#
# Artifacts: /tmp/ganesha-mount-sync/ (fio jobs, logs, CSV)
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
MODES=${MODES:-"async sync"}
CASES=${CASES:-all}
FIO=${FIO:-$(command -v fio || echo /usr/local/bin/fio)}
TIMEOUT=${TIMEOUT:-1800}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-mount-sync}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}
NS=${K8S_NS:-ganesha-seaweedfs}
FLUSH_WAIT=${FLUSH_WAIT:-130}

mkdir -p "$ARTIFACT_DIR"
[ -f "$CSV" ] || printf 'mode,case,rw,bs,direct,repeat,bw,iops,clat_ms,rc\n' > "$CSV"

say() { echo "$*"; }
bad() { echo "  *** FAILED: $*" >&2; }
want() { [ "$CASES" = all ] && return 0; case " $CASES " in *" $1 "*) return 0 ;; esac; return 1; }
DS=$DATA/ms-data.0

datsize() { kubectl -n "$NS" exec seaweedfs-volume-0 -- du -sb /data/vol 2>/dev/null | cut -f1; }

vacuum() {
  local prev=-1 cur i
  say "--- delete flush wait ${FLUSH_WAIT}s, then vacuum"
  sleep "$FLUSH_WAIT"
  printf 'lock\nvolume.vacuum\nunlock\nexit\n' | \
    kubectl -n "$NS" exec -i deploy/seaweedfs-master -- \
      /usr/local/bin/weed shell -master=127.0.0.1:9333 >/dev/null 2>&1 || true
  # Vacuum is asynchronous; poll until the .dat total stops shrinking.
  for i in $(seq 1 30); do
    cur=$(datsize); case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    say "    .dat $(awk -v x="$cur" 'BEGIN{printf "%.1f GiB", x/1073741824}')"
    [ "$cur" -eq "$prev" ] && break
    prev=$cur
    sleep 15
  done
}

remount() { # <async|sync>
  local mode=$1 opts=$NFS_OPTS
  [ "$mode" = sync ] && opts="$opts,sync"
  sudo umount -l "$MNT" 2>/dev/null || true
  sudo mount -t nfs -o "$opts" "$NODE_IP:/seaweedfs" "$MNT" || { echo "ERROR: mount failed ($mode)" >&2; return 1; }
  is_mounted "$MNT" || { echo "ERROR: mount not visible ($mode)" >&2; return 1; }
  say "--- mount: $mode ($opts)"
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
  say "=== dataset $SIZE (under async mount) ==="
  timeout 900 "$FIO" "$job" > "$log" 2>&1 || bad "prep rc=$? ($log)"
}

run_case() { # <name> <rw> <bs> <direct> <qd> <runtime> <fresh|ds>
  local name=$1 rw=$2 bs=$3 direct=$4 qd=$5 runtime=$6 src=$7
  local job="$ARTIFACT_DIR/${MODE}-${name}-r${REP}.fio"
  local log="$ARTIFACT_DIR/${MODE}-${name}-r${REP}.log"
  local fp

  if [ "$src" = fresh ]; then
    # One file per case/mode, reused across reps: rep 1 is a fresh file
    # (fio lays it out, untimed), reps 2+ overwrite it -- same semantics
    # as the main matrix.  The mode-end cleanup removes it.
    fp="$DATA/ms-${name}-${MODE}.0"
  else
    fp=$DS
  fi

  cat > "$job" <<EOF
[global]
ioengine=libaio
rw=$rw
bs=$bs
direct=$direct
iodepth=$qd
numjobs=1
size=$SIZE
filename=$fp
fallocate=none
scramble_buffers=1
group_reporting=1
EOF
  [ "$runtime" -gt 0 ] && printf 'time_based=1\nruntime=%s\n' "$runtime" >> "$job"
  printf '\n[%s]\n' "$name" >> "$job"
  case "$rw" in write|randwrite) echo "end_fsync=1" >> "$job" ;; esac

  say "=== [$MODE] $name run $REP/$REPEAT (rw=$rw bs=$bs direct=$direct qd=$qd) ==="
  timeout "$TIMEOUT" "$FIO" "$job" > "$log" 2>&1
  local rc=$?
  [ "$rc" = 0 ] || bad "$name rc=$rc; see $log"

  local bw iops cunit craw clat
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

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$MODE" "$name" "$rw" "$bs" "$direct" "$REP" "$bw" "$iops" "$clat" "$rc" >> "$CSV"
  say "  bw=$bw iops=$iops clat=${clat}ms rc=$rc"
}

restore() { remount async >/dev/null 2>&1 || true; }
trap restore EXIT

for MODE in $MODES; do
  remount async || exit 1
  prep_dataset
  [ "$MODE" = async ] || { remount "$MODE" || exit 1; }
  for REP in $(seq 1 "$REPEAT"); do
    want seq-write-1m-buf  && run_case seq-write-1m-buf  write     1M  0 16  0 fresh
    want seq-write-4m-dir  && run_case seq-write-4m-dir  write     4M  1  8  0 fresh
    want seq-write-8m-dir  && run_case seq-write-8m-dir  write     8M  1  4  0 fresh
    want seq-write-4k-dir  && run_case seq-write-4k-dir  write     4k  1 32 60 ds
    want rand-write-4k-dir && run_case rand-write-4k-dir randwrite 4k  1 32 60 ds
    want rand-write-64k-dir && run_case rand-write-64k-dir randwrite 64k 1 32 60 ds
    want rand-write-1m-dir && run_case rand-write-1m-dir randwrite 1M  1 16 60 ds
  done
  # Remove this mode's data, flush the deletes, and vacuum before the
  # next mode so the 64 x 4 GiB pool never fills up (ENOSPC).
  restore
  rm -f "$DS" "$DATA"/ms-*.0
  sync
  vacuum
done

restore
rm -f "$DS" "$DATA"/ms-*.0
sync
say ""
say "CSV: $CSV"
say "NOTE: each mode ends with a vacuum; check the final .dat total."
