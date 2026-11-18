#!/bin/bash
# =====================================================================
# bench-ganesha-seaweedfs-arms.sh - host vs pod Ganesha/FUSE comparison
#
#   usage: bash bench-ganesha-seaweedfs-arms.sh host|pod|both|compare
#
# Both arms use the same host fio client and the same SeaweedFS backend
# (node-IP hostPorts), so only the Ganesha + weed FUSE placement changes:
#
#   host: host Ganesha + host weed FUSE   -> /mnt/ganesha-host-arm/data
#   pod:  pod Ganesha  + pod weed FUSE    -> /mnt/ganesha-seaweedfs/data
#
# Cases: buffered-1m, buffered-4m, odirect-1m, odirect-4m, odirect-8m,
# buffered-8job.  Select a subset with CASES="buffered-4m odirect-4m".
#
# Each case runs REPEAT times.  Every run gets a .dat landing check
# (R4).  After the repeats of a case, the case files are deleted, the
# filer change log for today is removed and the volumes are vacuumed,
# so the next case starts from the same state.
#
#   SIZE=6G CONC_SIZE=1G REPEAT=3
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

NS=${K8S_NS:-ganesha-seaweedfs}
NODE_IP=${NODE_IP:-172.18.0.2}
HOST_MNT=${HOST_MNT:-/mnt/ganesha-host-arm}
POD_MNT=${POD_MNT:-/mnt/ganesha-seaweedfs}
HOST_DIR=${HOST_DIR:-$HOST_MNT/data}
POD_DIR=${POD_DIR:-$POD_MNT/data}
REPEAT=${REPEAT:-3}
SIZE=${SIZE:-6G}
CONC_SIZE=${CONC_SIZE:-1G}
FIO=${FIO:-/usr/local/bin/fio}
FIO_TIMEOUT=${FIO_TIMEOUT:-1800}
LAND_WAIT=${LAND_WAIT:-300}
VACUUM_WAIT=${VACUUM_WAIT:-300}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-seaweedfs-arms}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}
ALL_CASES=${ALL_CASES:-"buffered-1m buffered-4m odirect-1m odirect-4m odirect-8m buffered-8job"}
CASES=${CASES:-$ALL_CASES}
KUBECTL=${KUBECTL:-kubectl}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi

ARM=${1:-both}
FAIL=0
say() { echo "$*"; }
bad() { printf "  %-56s *** FAILED: %s\n" "$1" "$2"; FAIL=1; }

datsize() { K8S_NS="$NS" bash "$HERE/k8s-volume-datsize.sh"; }

arm_mounts() { # <arm>; sets MNT and DATA
  case "$1" in
    host) MNT=$HOST_MNT; DATA=$HOST_DIR ;;
    pod)  MNT=$POD_MNT;  DATA=$POD_DIR ;;
    *) echo "ERROR: unknown arm '$1'" >&2; exit 2 ;;
  esac
}

check_arm() { # <arm>
  arm_mounts "$1"
  if is_mounted "$MNT"; then
    say "  $1 arm: $MNT is mounted, data dir $DATA"
  else
    say "ERROR: $MNT is not mounted"
    say "  host arm: bash $HERE/host-arm-ganesha-seaweedfs.sh up"
    say "  pod arm:  mount 172.18.0.2:/seaweedfs on $POD_MNT (port 32049)"
    exit 1
  fi
  [ -d "$DATA" ] || { say "ERROR: $DATA is not there"; exit 1; }
}

# --- cleanup after a case ------------------------------------------------

vacuum_case() {
  printf 'fs.rm -r /topics/.system/log/%s\nexit\n' "$(date +%F)" \
    | timeout 60 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-filer -- \
        /usr/local/bin/weed shell -master="$NODE_IP:9333" >/dev/null 2>&1 || true
  printf 'lock\nvolume.vacuum\nunlock\nexit\n' \
    | timeout 120 "$KUBECTL" -n "$NS" exec -i deploy/seaweedfs-master -- \
        /usr/local/bin/weed shell -master=127.0.0.1:9333 >/dev/null 2>&1 || true
  wait_size_stable "K8S_NS=$NS bash $HERE/k8s-volume-datsize.sh" 5 "$VACUUM_WAIT" || true
}

# --- one case ------------------------------------------------------------

run_case() { # <arm> <case> <bs> <direct> <jobs> <size>
  local arm=$1 case_name=$2 bs=$3 direct=$4 jobs=$5 size=$6
  local mnt data prefix rep job log before after expected wait rc bw craw cunit clat delta
  local out

  arm_mounts "$arm"
  mnt=$MNT; data=$DATA
  prefix="bench-${arm}-${case_name}-$(date +%Y%m%d-%H%M%S)-$$"
  expected=$(( $(numfmt --from=iec "$size") * jobs ))

  for rep in $(seq 1 "$REPEAT"); do
    job="$ARTIFACT_DIR/${arm}-${case_name}-r${rep}.fio"
    log="$ARTIFACT_DIR/${arm}-${case_name}-r${rep}.log"
    before=$(datsize)
    case "$before" in ''|*[!0-9]*) before=0 ;; esac

    cat > "$job" <<EOF
[global]
ioengine=libaio
rw=write
bs=$bs
direct=$direct
iodepth=16
size=$size
fallocate=none
end_fsync=1
scramble_buffers=1
directory=$data
filename_format=${prefix}-r${rep}.\$jobnum
group_reporting=1

[${prefix}-r${rep}]
numjobs=$jobs
EOF

    say "=== $arm/$case_name run $rep/$REPEAT (bs=$bs direct=$direct jobs=$jobs size/job=$size) ==="
    timeout "$FIO_TIMEOUT" "$FIO" "$job" > "$log" 2>&1
    rc=$?
    if [ "$rc" != "0" ]; then
      bad "$arm/$case_name run $rep" "fio rc=$rc; see $log"
      tail -10 "$log" | sed 's/^/    /'
    fi

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

    wait=0
    after=$before
    while [ "$((after - before))" -lt "$((expected / 2))" ] && [ "$wait" -lt "$LAND_WAIT" ]; do
      sleep 2
      wait=$((wait + 2))
      after=$(datsize)
      case "$after" in ''|*[!0-9]*) after=$before ;; esac
    done
    delta=$((after - before))
    if [ "$delta" -lt "$((expected / 2))" ]; then
      bad "$arm/$case_name run $rep landing" "only $delta of $expected bytes reached .dat"
    fi

    out="$ARTIFACT_DIR/${arm}-${case_name}-r${rep}.out"
    {
      echo "date: $(date -Is)"
      echo "arm: $arm"
      echo "case: $case_name run $rep"
      echo "mount: $mnt dir: $data"
      echo "fio: $($FIO --version 2>&1 | grep -oE 'fio-[0-9.]+' | head -1)"
      echo "bs: $bs direct: $direct jobs: $jobs size/job: $size"
      echo "expected: $expected landed: $delta rc: $rc bw: $bw clat_ms: $clat"
    } > "$out"

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$arm" "$case_name" "$rep" "${bw:-unknown}" "${clat:-0}" "$expected" "$delta" "$rc" >> "$CSV"
    say "  bw=${bw:-unknown} clat=${clat:-0}ms landed=${delta}B"
  done

  # Clean up this case (the three repeats) before the next case.
  rm -f "$data/$prefix-r"*
  sync
  vacuum_case
}

stats_line() { # <arm> <case>
  awk -F, -v a="$1" -v c="$2" '
    $1 == a && $2 == c {
      v = $4; gsub(/[A-Za-z\/]+/, "", v); v += 0
      if ($4 ~ /GiB\/s/) v *= 1024
      else if ($4 ~ /KiB\/s/) v /= 1024
      n++; b[n] = v; s += v
      if ($5 ~ /^[0-9.]+$/) { cn++; cs += $5 }
    }
    END {
      if (!n) { print "n/a"; exit }
      m = s / n
      for (i = 1; i <= n; i++) {
        d = b[i] - m; ss += d * d
        if (i == 1 || b[i] < mn) mn = b[i]
        if (i == 1 || b[i] > mx) mx = b[i]
      }
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (b[i] > b[j]) { t = b[i]; b[i] = b[j]; b[j] = t }
      med = (n % 2) ? b[(n + 1) / 2] : (b[n / 2] + b[n / 2 + 1]) / 2
      printf "mean=%.1f med=%.1f min=%.1f max=%.1f spread=%.1f sd=%.1f clat=%.1fms", \
             m, med, mn, mx, mx - mn, sqrt(ss / n), (cn ? cs / cn : 0)
    }' "$CSV"
}

mean_bw() { # <arm> <case>
  awk -F, -v a="$1" -v c="$2" '
    $1 == a && $2 == c {
      v = $4; gsub(/[A-Za-z\/]+/, "", v); v += 0
      if ($4 ~ /GiB\/s/) v *= 1024
      else if ($4 ~ /KiB\/s/) v /= 1024
      s += v; n++
    }
    END { if (n) printf "%.1f", s / n; else printf "n/a" }' "$CSV"
}

case_params() { # <case> -> "bs direct jobs size"
  case "$1" in
    buffered-1m)   echo "1M 0 1 $SIZE" ;;
    buffered-4m)   echo "4M 0 1 $SIZE" ;;
    odirect-1m)    echo "1M 1 1 $SIZE" ;;
    odirect-4m)    echo "4M 1 1 $SIZE" ;;
    odirect-8m)    echo "8M 1 1 $SIZE" ;;
    buffered-8job) echo "1M 0 8 $CONC_SIZE" ;;
    *) echo "ERROR: unknown case '$1'" >&2; exit 2 ;;
  esac
}

run_arm() { # <arm>
  local arm=$1 c spec bs direct jobs size
  say ""
  say "########## $arm arm ##########"
  check_arm "$arm"

  for c in $CASES; do
    spec=$(case_params "$c")
    read -r bs direct jobs size <<< "$spec"
    run_case "$arm" "$c" "$bs" "$direct" "$jobs" "$size"
  done

  say ""
  say "=== $arm summary (MiB/s) ==="
  printf '  %-16s %s\n' "case" "mean/median/min/max/spread/stdev/clat"
  for c in $CASES; do
    printf '  %-16s %s\n' "$c" "$(stats_line "$arm" "$c")"
  done
}

compare_arms() {
  local c h p d
  say ""
  say "=== host vs pod (mean MiB/s) ==="
  printf '  %-16s %10s %10s %10s\n' "case" "host" "pod" "host-pod%"
  for c in $CASES; do
    h=$(mean_bw host "$c")
    p=$(mean_bw pod "$c")
    if [ "$h" != "n/a" ] && [ "$p" != "n/a" ]; then
      d=$(awk -v h="$h" -v p="$p" 'BEGIN{ if (p > 0) printf "%+.1f%%", (h - p) / p * 100; else printf "n/a" }')
    else
      d="n/a"
    fi
    printf '  %-16s %10s %10s %10s\n' "$c" "$h" "$p" "$d"
  done
}

# --- main -----------------------------------------------------------------

mkdir -p "$ARTIFACT_DIR"
if [ ! -f "$CSV" ]; then
  printf 'arm,case,repeat,bw,clat_avg_ms,expected_bytes,landed_bytes,rc\n' > "$CSV"
fi

case "$ARM" in
  host)    run_arm host ;;
  pod)     run_arm pod ;;
  both)    run_arm host; run_arm pod; compare_arms ;;
  compare) compare_arms ;;
  *) echo "usage: $0 host|pod|both|compare" >&2; exit 2 ;;
esac

say ""
say "CSV: $CSV"
say "Per-run fio job files and logs: $ARTIFACT_DIR"
[ "$FAIL" = "0" ] && say "RESULT: PASS" || say "RESULT: FAIL"
exit "$FAIL"
