#!/bin/bash
# =====================================================================
# bench-ganesha-fio-matrix.sh - typical fio matrix on the Ganesha/FUSE
# export, under the "auto" durability tier:
#
#   * no filer fsync storage rule
#   * vm.dirty_expire_centisecs=100, vm.dirty_writeback_centisecs=100
#   * RPC_Ioq_ThrdMax=200, FUSE writers/readers=64, chunk 8, tmpfs cache
#
# Cases: sequential write/read at 1M/4M/8M, small sequential 4K,
# random write/read at 4K/64K/1M.  Reads use O_DIRECT and drop the
# VM page cache first, so they measure the backend path, not a warm cache.
#
#   usage: bash bench-ganesha-fio-matrix.sh [pod|host] [repeat]
#
# Artifacts: /tmp/ganesha-fio-matrix/ (fio jobs, logs, CSV)
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

NS=${K8S_NS:-ganesha-seaweedfs}
NODE_IP=${NODE_IP:-172.18.0.2}
POD_MNT=${POD_MNT:-/mnt/ganesha-seaweedfs}
HOST_MNT=${HOST_MNT:-/mnt/ganesha-host-arm}
ARM=${1:-pod}
REPEAT=${2:-1}
FIO=${FIO:-/usr/local/bin/fio}
[ -x "$FIO" ] || FIO=fio
TIMEOUT=${TIMEOUT:-1800}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-fio-matrix}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}
CASES=${CASES:-all}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

case "$ARM" in
  pod)  MNT=$POD_MNT ;;
  host) MNT=$HOST_MNT ;;
  *) echo "usage: $0 [pod|host] [repeat]" >&2; exit 2 ;;
esac
DATA=$MNT/data

mkdir -p "$ARTIFACT_DIR"
[ -f "$CSV" ] || printf 'arm,case,rw,bs,direct,iodepth,jobs,size,repeat,bw,iops,clat_ms,rc\n' > "$CSV"

say() { echo "$*"; }
bad() { echo "  *** FAILED: $*" >&2; }
want() { [ "$CASES" = all ] && return 0; case " $CASES " in *" $1 "*) return 0 ;; esac; return 1; }

datsize() { K8S_NS="$NS" bash "$HERE/k8s-volume-datsize.sh"; }

is_mounted "$MNT" || { echo "ERROR: $MNT is not mounted (start the pod/host arm first)"; exit 1; }
[ -d "$DATA" ] || { echo "ERROR: $DATA not found"; exit 1; }

drop_caches() {
  # The Ganesha/FUSE pod is privileged and shares the kind node kernel,
  # so this drops the VM's page cache (and the SeaweedFS volume cache).
  "$KUBECTL" -n "$NS" exec deploy/seaweedfs-ganesha-fuse -- \
    sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1 \
    || echo "  (warning: drop_caches failed; read may hit page cache)"
}

# --- dataset preparation (not measured) --------------------------------

prep_file() { # <name> <size>
  local name=$1 size=$2
  local job="$ARTIFACT_DIR/prep-$name.fio" log="$ARTIFACT_DIR/prep-$name.log"
  if [ -f "$DATA/$name" ]; then
    say "  dataset $name exists"
    return 0
  fi
  say "  preparing dataset $name ($size, sequential 1M direct)"
  cat > "$job" <<EOF
[global]
ioengine=libaio
rw=write
bs=1M
direct=1
iodepth=16
numjobs=1
size=$size
filename=$DATA/$name
fallocate=none
end_fsync=1
scramble_buffers=1
group_reporting=1

[prep-$name]
EOF
  timeout "$TIMEOUT" "$FIO" "$job" > "$log" 2>&1 || bad "prep $name rc=$? ($log)"
}

prepare_datasets() {
  say "=== datasets ==="
  # >8 GiB so the data spans more than two 4 GiB SeaweedFS volumes.
  prep_file data12g.0 12G
}

# --- one case ------------------------------------------------------------

run_case() { # <case> <rw> <bs> <direct> <iodepth> <jobs> <size> <file|-> <landing> <runtime>
  local case_name=$1 rw=$2 bs=$3 direct=$4 iodepth=$5 jobs=$6 size=$7 file=$8 landing=${9:-no} runtime=${10:-0}
  local rep job log filepath before after expected delta rc bw iops cunit craw clat wait warm
  local stamp="$(date +%Y%m%d-%H%M%S)-$$"

  if [ "$file" = "-" ]; then
    filepath="$DATA/matrix-${case_name}-${stamp}.0"
  else
    filepath="$DATA/$file"
  fi

  for rep in $(seq 1 "$REPEAT"); do
    job="$ARTIFACT_DIR/${case_name}-r${rep}.fio"
    log="$ARTIFACT_DIR/${case_name}-r${rep}.log"

    cat > "$job" <<EOF
[global]
ioengine=libaio
rw=$rw
bs=$bs
direct=$direct
iodepth=$iodepth
numjobs=$jobs
size=$size
filename=$filepath
fallocate=none
scramble_buffers=1
group_reporting=1
EOF
    [ "$runtime" -gt 0 ] && printf 'time_based=1\nruntime=%s\n' "$runtime" >> "$job"
    printf '\n[%s-r%s]\n' "$case_name" "$rep" >> "$job"
    # Writes: wait for the backend drain, like the standard benchmark.
    case "$rw" in write|randwrite) echo "end_fsync=1" >> "$job" ;; esac

    before=$(datsize); case "$before" in ''|*[!0-9]*) before=0 ;; esac
    if [ "$rw" = read ] || [ "$rw" = randread ]; then
      drop_caches
      # drop_caches can evict the FUSE inode; a stat is not enough (the
      # 4M/8M reads still hit a transient ENOENT at fio open).  Open and
      # read one block, retrying until the lookup is warm.
      for warm in 1 2 3 4 5; do
        dd if="$filepath" of=/dev/null bs=1M count=1 iflag=direct >/dev/null 2>&1 && break
        sleep 1
      done
    fi

    say "=== $case_name run $rep/$REPEAT (rw=$rw bs=$bs direct=$direct qd=$iodepth jobs=$jobs size=$size) ==="
    timeout "$TIMEOUT" "$FIO" "$job" > "$log" 2>&1
    rc=$?
    [ "$rc" = 0 ] || bad "$case_name rc=$rc; see $log"

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

    delta=0
    if [ "$landing" = yes ]; then
      expected=$(( $(numfmt --from=iec "$size") * jobs ))
      wait=0
      after=$before
      while [ "$((after - before))" -lt "$((expected / 2))" ] && [ "$wait" -lt 120 ]; do
        sleep 2; wait=$((wait + 2)); after=$(datsize)
        case "$after" in ''|*[!0-9]*) after=$before ;; esac
      done
      delta=$((after - before))
      [ "$delta" -ge "$((expected / 2))" ] || bad "$case_name landing only $delta / $expected bytes"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ARM" "$case_name" "$rw" "$bs" "$direct" "$iodepth" "$jobs" "$size" "$rep" \
      "$bw" "$iops" "$clat" "$rc" >> "$CSV"
    say "  bw=$bw iops=$iops clat=${clat}ms landed=${delta}B rc=$rc"
  done

  [ "$file" = "-" ] && rm -f "$filepath"
}

# --- main -----------------------------------------------------------------

say "########## $ARM arm: $MNT (repeat=$REPEAT) ##########"
prepare_datasets

want seq-write-1m-buf  && run_case seq-write-1m-buf  write     1M  0 16 1 12G -         yes 0
want seq-write-4m-dir  && run_case seq-write-4m-dir  write     4M  1  8 1 12G -         yes 0
want seq-write-8m-dir  && run_case seq-write-8m-dir  write     8M  1  4 1 12G -         yes 0
want seq-read-1m-dir   && run_case seq-read-1m-dir   read      1M  1 16 1 12G data12g.0 no  0
want seq-read-4m-dir   && run_case seq-read-4m-dir   read      4M  1  8 1 12G data12g.0 no  0
want seq-read-8m-dir   && run_case seq-read-8m-dir   read      8M  1  4 1 12G data12g.0 no  0
want seq-write-4k-dir  && run_case seq-write-4k-dir  write     4k  1 32 1 12G data12g.0 no  60
want seq-read-4k-dir   && run_case seq-read-4k-dir   read      4k  1 32 1 12G data12g.0 no  60
want rand-write-4k-dir && run_case rand-write-4k-dir randwrite 4k  1 32 1 12G data12g.0 no  60
want rand-read-4k-dir  && run_case rand-read-4k-dir  randread  4k  1 32 1 12G data12g.0 no  60
want rand-write-64k-dir && run_case rand-write-64k-dir randwrite 64k 1 32 1 12G data12g.0 no  60
want rand-read-64k-dir && run_case rand-read-64k-dir randread  64k 1 32 1 12G data12g.0 no  60
want rand-write-1m-dir && run_case rand-write-1m-dir randwrite 1M  1 16 1 12G data12g.0 no  60
want rand-read-1m-dir  && run_case rand-read-1m-dir  randread  1M  1 16 1 12G data12g.0 no  60

say ""
say "=== summary ==="
awk -F, 'NR>1 {printf "  %-20s %10s %10s %10s\n", $2, $10, $11, $12}' "$CSV"
say ""
say "CSV: $CSV"
say "fio jobs/logs: $ARTIFACT_DIR"
say "NOTE: datasets remain; clean up with the standard rm + remount/restart + topics rm + vacuum sequence."
