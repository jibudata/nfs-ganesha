#!/usr/bin/env bash
# SeaweedFS FUSE-layer baseline (Baseline B of the Ganesha+FUSE perf matrix)
#
# Concurrency notes (verified empirically on this host):
#   - fio GROUPS run sequentially (stonewall default) -> use ONE group
#   - jobs within a group run CONCURRENTLY -> use numjobs=N
#   - each concurrent job MUST get its own file -> filename_format=<label>.$jobnum
#
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env
# Shared helpers: pids_of_re. See LAB-CONVENTIONS.md R1.
. "$(dirname "$0")/lib-nfslab.sh"

MNT="$SW_MNT"
SCRATCH="$SW_ROOT/scratch"
FIO=/usr/local/bin/fio
mkdir -p "$SCRATCH"

# mk_jobfile <label> <numjobs> <bs> <size> <dir> <engine> <extra-fio-args...>
mk_jobfile() {
  local label=$1 nj=$2 bs=$3 size=$4 dir=$5 engine=$6; shift 6
  {
    printf '[global]\n'
    printf 'ioengine=%s\n' "$engine"
    printf 'rw=write\n'
    printf 'bs=%s\n' "$bs"
    printf 'iodepth=16\n'
    printf 'size=%s\n' "$size"
    printf 'directory=%s\n' "$dir"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in "$@"; do printf '%s\n' "$a"; done
  } > "/tmp/fio-$label.fio"
}

run_case() {
  local label=$1 nj=$2 bs=$3 size=$4 dir=$5 engine=$6; shift 6
  local before after start end
  mk_jobfile "$label" "$nj" "$bs" "$size" "$dir" "$engine" "$@"
  before=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
  start=$(date +%s.%N)
  timeout 900 "$FIO" "/tmp/fio-$label.fio" > "/tmp/fio-$label.out" 2>&1
  local rc=$?
  end=$(date +%s.%N)
  after=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
  local growth=$(( (after - before) / 1024 / 1024 ))
  local el=$(echo "$end - $start" | bc)
  printf '  %-46s rc=%-3s elapsed=%6.1fs  volume_growth=%6s MiB\n' \
    "$label" "$rc" "$el" "$growth"
  grep -E "write: IOPS|^  WRITE:" "/tmp/fio-$label.out" | head -3 | sed 's/^/      /'
  if [ "$rc" -ne 0 ]; then
    echo "      !! fio rc=$rc"; tail -5 "/tmp/fio-$label.out" | sed 's/^/      /'
  fi
}

echo "############################################################"
echo "# SeaweedFS FUSE baseline   $(date -Is)"
echo "# host=$(hostname)  mount=$MNT"
echo "# weed=$(weed version 2>&1 | head -1)"
echo "############################################################"
echo
echo "--- Baseline A: raw NVMe/ext4, no FUSE, no NFS (reference ceiling) ---"
run_case A_raw_ext4_1job 1 1M 8G "$SCRATCH" libaio
echo
echo "--- Baseline B: SeaweedFS FUSE mount, single writer ---"
run_case B1_fuse_1M_1job 1 1M 8G "$MNT" libaio
run_case B3_fuse_128k_1job 1 128k 4G "$MNT" libaio
echo
echo "--- Baseline B: concurrency scaling (distinct file per job) ---"
run_case B2_fuse_1M_4job 4 1M 2G "$MNT" libaio
run_case B5_fuse_1M_8job 8 1M 1G "$MNT" libaio
echo
echo "--- Persistence semantics: fdatasync per write ---"
run_case B4_fuse_fdatasync 1 1M 2G "$MNT" psync --fdatasync=1
echo
echo "--- FUSE connection state after the run ---"
for d in /sys/fs/fuse/connections/*; do
  [ -d "$d" ] || continue
  mb=$(cat "$d/max_background" 2>/dev/null)
  ct=$(cat "$d/congestion_threshold" 2>/dev/null)
  wt=$(cat "$d/waiting" 2>/dev/null)
  tag=" "
  [ "$mb" = "$SW_MAX_BACKGROUND" ] && tag="*"
  printf '  %s conn=%-4s max_background=%-6s congestion_threshold=%-6s waiting=%s\n' \
    "$tag" "$(basename "$d")" "$mb" "$ct" "$wt"
done
echo
echo "--- seaweedfs process CPU time (cumulative jiffies) ---"
for p in $(pids_of_re "weed (master|server|filer|mount)"); do
  nm=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | awk '{print $2}')
  st=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)
  printf '  pid=%-7s %-8s cpu_jiffies=%s\n' "$p" "$nm" "$st"
done
echo
echo "--- cleanup ---"
rm -f "$MNT"/A_raw_ext4_1job.* "$MNT"/B1_fuse_1M_1job.* "$MNT"/B3_fuse_128k_1job.* \
      "$MNT"/B2_fuse_1M_4job.* "$MNT"/B5_fuse_1M_8job.* "$MNT"/B4_fuse_fdatasync.* \
      "$SCRATCH"/A_raw_ext4_1job.*
rm -f /tmp/fio-*.fio /tmp/fio-*.out
echo "  done"
