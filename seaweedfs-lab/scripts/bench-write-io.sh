#!/usr/bin/env bash
# =====================================================================
# Write I/O test harness for the full chain:
#   NFS client -> NFS-Ganesha V15.9 (FSAL_VFS) -> FUSE (SeaweedFS 4.54)
#              -> weed filer -> weed volume server -> NVMe
#
# For every case it captures:
#   * fio throughput (group aggregate) / total IOPS / IO errors
#   * Ganesha-side NFSv4 WRITE op count and average latency (from Prometheus)
#   * RPC counter deltas
#   * CPU jiffies consumed by ganesha / weed mount / weed volume server
#   * volume-server .dat growth  (proves the data actually reached storage)
#
# All runs use a non-root client user because the export uses Root_Squash.
# =====================================================================
set -uo pipefail
# Shared helpers: lazy_unmount / pids_of. See LAB-CONVENTIONS.md R1/R3.
. "$(dirname "$0")/lib-nfslab.sh"

CRASHED=0
SRV=192.168.3.146
FIO=/usr/local/bin/fio
METRICS=http://127.0.0.1:32000/metrics
MNT_V4=/mnt/ganesha-test
MNT_V3=/mnt/ganesha-v3
FUSE_MNT=/home/ys1000/seaweedfs/mnt
DATA=/home/ys1000/seaweedfs/data
CSV=/home/ys1000/seaweedfs/logs/bench-write-io.csv

# ---------------------------------------------------------------- helpers
scrape() { curl -sS -m 10 "$METRICS" -o "$1" 2>/dev/null; }

# Sum a Prometheus metric over every label combination (status="..." etc).
# Prometheus client emits plain decimal, but keep it float-safe.
msum() { # <file> <metric> [label-regex]
  awk -v m="$2" -v p="${3:-}" '
    $1 ~ /^#/ { next }
    { key=$1; sub(/\{.*$/, "", key)
      if (key==m && (p=="" || $0 ~ p)) { s += $2; n++ } }
    END { if (n>0) printf "%.6f", s; else printf "0" }' "$1" 2>/dev/null
}

# Difference of the same metric between two scrapes (float-safe).
mdelta() { # <file-before> <file-after> <metric> [label-regex]
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

# cputicks <pid> -> utime+stime jiffies
cputicks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

pid_of() { pids_of "$1" | head -1; }

# Match the ganesha daemon by process NAME: `pgrep -f "ganesha.nfsd -f"` also
# matches any shell whose command line happens to contain that string
# (e.g. the ssh wrapper running this very script).
pid_ganesha() { pgrep -x "ganesha.nfsd" | head -1; }

# Sum the volume-server .dat sizes without reading them (cat-ing them is
# O(total data) per case and gets expensive once the matrix has written ~40 GiB).
volbytes() {
  find "$DATA" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END{printf "%d\n", s+0}'
}

# fio output parsing ------------------------------------------------------
# NOTE: fio prints one "write: IOPS=..., BW=...MiB/s ..." line PER JOB and a
# single group summary "WRITE: bw=..." line with the aggregate.  Taking the
# first BW= line would report only job #1, so the aggregate is taken from the
# group summary and IOPS are summed over all jobs.
parse_fio() { # <outfile> -> sets BW_MIB / IOPS_TOTAL / ERR_TOTAL
  local f=$1 line bw num unit
  BW_MIB=0; IOPS_TOTAL=0; ERR_TOTAL=0
  [ -r "$f" ] || return 1

  line=$(grep -E '^[[:space:]]*WRITE:[[:space:]]*bw=' "$f" | head -1)
  if [ -z "$line" ]; then
    line=$(grep -oE 'BW=[0-9.]+[KMG]iB/s' "$f" | head -1)
    bw=$(echo "$line" | cut -d= -f2)
  else
    bw=$(echo "$line" | grep -oE 'bw=[0-9.]+[KMG]iB/s' | head -1 | cut -d= -f2)
  fi
  if [ -n "${bw:-}" ]; then
    num=${bw%%[KMG]iB/s}
    unit=${bw#$num}
    case "$unit" in
      KiB/s) BW_MIB=$(echo "scale=2; $num/1024"   | bc) ;;
      MiB/s) BW_MIB=$(echo "scale=2; $num"         | bc) ;;
      GiB/s) BW_MIB=$(echo "scale=2; $num*1024"    | bc) ;;
      *)     BW_MIB=0 ;;
    esac
  fi

  IOPS_TOTAL=$(grep -oE 'IOPS=[0-9.]+[kKmM]?' "$f" | cut -d= -f2 | awk '{
      v=$0; m=1
      if (v ~ /[kK]$/)      { m=1000;    v=substr(v,1,length(v)-1) }
      else if (v ~ /[mM]$/) { m=1000000; v=substr(v,1,length(v)-1) }
      s += v*m } END { printf "%d", s+0 }')
  ERR_TOTAL=$(grep -oE 'err= *[0-9]+' "$f" | grep -oE '[0-9]+' \
              | awk '{s+=$1} END{printf "%d", s+0}')
  return 0
}

# NOTE: this MUST be a function, not a variable holding a command string.
# A variable expands to multiple words and the shell does NOT re-parse the
# quotes inside it, so `ROW="printf '...'"` + `$ROW a b c` mis-renders the
# whole table (it worked by accident only because printf reuses its format).
row() {
  printf '%-26s %10s %10s %8s %10s %9s %8s %8s %8s %8s\n' "$@"
}

print_header() {
  echo
  printf '%-26s %10s %10s %8s %10s %9s %8s %8s %8s %8s\n' \
    "CASE" "MiB/s" "IOPS" "err" "avgLatMs" "rpc/s" "WRITEops" "ganCPU" "fuseCPU" "diskMiB"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------"
}

# run_case <label> <mountpoint> <numjobs> <bs> <size> <direct 0|1> <engine> [extra fio args...]
run_case() {
  local label=$1 mnt=$2 nj=$3 bs=$4 size=$5 direct=$6 engine=$7; shift 7

  local jf="/tmp/fio-$label.fio"
  {
    printf '[global]\n'
    printf 'ioengine=%s\n' "$engine"
    printf 'rw=write\n'
    printf 'bs=%s\n' "$bs"
    printf 'direct=%s\n' "$direct"
    if [ "$engine" = "libaio" ]; then
      printf 'iodepth=16\n'
    else
      printf 'iodepth=1\n'
    fi
    printf 'size=%s\n' "$size"
    printf 'directory=%s\n' "$mnt"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
    for a in "$@"; do printf '%s\n' "$a"; done
  } > "$jf"

  scrape /tmp/mb.txt
  local g0=$(cputicks $PID_GAN) w0=$(cputicks $PID_WMOUNT) v0=$(cputicks $PID_WSRV)
  local d0=$(volbytes)
  local t0=$(date +%s.%N)
  local pid0=$(pid_ganesha)
  local rs0=$(systemctl show ganesha -p NRestarts --value 2>/dev/null || echo 0)

  timeout 900 "$FIO" "$jf" > "/tmp/fio-$label.out" 2>&1
  local rc=$?

  local t1=$(date +%s.%N)
  scrape /tmp/ma.txt
  local g1=$(cputicks $PID_GAN) w1=$(cputicks $PID_WMOUNT) v1=$(cputicks $PID_WSRV)
  local d1=$(volbytes)

  # fio results
  parse_fio "/tmp/fio-$label.out"
  local bwmib=$BW_MIB iops=$IOPS_TOTAL fioerr=$ERR_TOTAL

  # Ganesha-side deltas
  local wop=$(mdelta /tmp/mb.txt /tmp/ma.txt "nfsv4__op_count" 'op="WRITE"')
  local wsum=$(mdelta /tmp/mb.txt /tmp/ma.txt "nfsv4__op_latency_sum" 'op="WRITE"')
  local wcnt=$(mdelta /tmp/mb.txt /tmp/ma.txt "nfsv4__op_latency_count" 'op="WRITE"')
  local lat=0
  [ "$(echo "$wcnt > 0" | bc)" -eq 1 ] && lat=$(echo "scale=3; $wsum / $wcnt" | bc)
  local rpc=$(mdelta /tmp/mb.txt /tmp/ma.txt "rpcs_received_total")

  local pid1=$(pid_ganesha)
  local rs1=$(systemctl show ganesha -p NRestarts --value 2>/dev/null || echo 0)
  local crashed=0
  [ "$pid0" != "$pid1" ] && crashed=1
  [ "$rs1" -gt "$rs0" ] && crashed=1

  local el=$(echo "$t1 - $t0" | bc)
  local rps=0
  [ "$(echo "$el > 0" | bc)" -eq 1 ] && rps=$(echo "scale=1; $rpc / $el" | bc)

  local gcpu=$(echo "scale=1; ($g1 - $g0) / 100" | bc)
  local wcpu=$(echo "scale=1; ($w1 - $w0) / 100" | bc)
  local dmb=$(( (d1 - d0) / 1024 / 1024 ))

  row "$label" "$bwmib" "$iops" "$fioerr" "$lat" "$rps" "$wop" "${gcpu}s" "${wcpu}s" "$dmb"
  echo "$label,$bwmib,$iops,$fioerr,$lat,$rps,$wop,$gcpu,$wcpu,$dmb,$rc" >> "$CSV"

  if [ "$rc" -ne 0 ]; then
    echo "    !! fio rc=$rc"; tail -6 "/tmp/fio-$label.out" | sed 's/^/    /'
  fi
  if [ "${fioerr:-0}" != "0" ]; then
    echo "    !! fio reported $fioerr IO error(s)"
  fi
  if [ "$crashed" -eq 1 ]; then
    echo "    !! ** GANESHA CRASHED during this case ** (pid $pid0 -> $pid1, restarts $rs0 -> $rs1)"
    echo "    !! core: $(ls -1 /var/lib/ganesha/core* 2>/dev/null | tail -1)"
    CRASHED=1
  fi

  # cleanup test files
  for f in "$mnt/$label".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
}

ensure_mount() { # <mountpoint> <vers> <server-path>
  local m=$1 v=$2 p=$3
  sudo mkdir -p "$m"
  lazy_unmount "$m"
  if sudo mount -t nfs -o "vers=$v,proto=tcp,rsize=1048576,wsize=1048576" \
       "$SRV:$p" "$m" 2>/dev/null; then
    echo "  mounted $m (vers=$v, 1MiB r/w)"
  else
    echo "  FAILED to mount $m (vers=$v)"
    return 1
  fi
}

# ---------------------------------------------------------------- setup
echo "### clean start: unmount stale NFS clients, restart ganesha for fresh counters ###"
for m in $(mount | grep "type nfs" | awk '{print $3}'); do
  echo "  unmount $m"; lazy_unmount "$m"
done
sleep 2
sudo systemctl restart ganesha
sleep 8
echo "  ganesha PID=$(pid_ganesha) NRestarts=$(systemctl show ganesha -p NRestarts --value)"

PID_GAN=$(pid_ganesha)
PID_WMOUNT=$(pid_of "weed mount")
PID_WSRV=$(pid_of "weed server")
PID_WFIL=$(pid_of "weed filer")
echo "pids: ganesha=$PID_GAN weed_mount=$PID_WMOUNT weed_server=$PID_WSRV weed_filer=$PID_WFIL"
echo "date: $(date -Is)"
echo "note: client and server are on the SAME host; NFS traffic uses the local"
echo "      br0 address (kernel TCP stack) and does NOT cross the 1GbE NIC."

echo "case,MiB_s,IOPS,io_err,avg_lat_ms,rpc_per_s,write_ops,ganesha_cpu_s,weedmount_cpu_s,disk_mib,fio_rc" > "$CSV"

ensure_mount "$MNT_V4" 4.1 /seaweedfs >/dev/null
ensure_mount "$MNT_V3" 3 /home/ys1000/seaweedfs/mnt >/dev/null

echo
echo "### Phase 0: repeatability (NFSv4.1, bs=1M, 1 job, O_DIRECT) - 3 identical runs ###"
print_header
run_case rep1_1M_1job "$MNT_V4" 1 1M 1G 1 libaio
run_case rep2_1M_1job "$MNT_V4" 1 1M 1G 1 libaio
run_case rep3_1M_1job "$MNT_V4" 1 1M 1G 1 libaio
[ "$CRASHED" -eq 1 ] && { echo "!! aborting matrix: ganesha crashed"; exit 2; }

echo
echo "### Phase 1: protocol comparison (bs=1M, 1 job, O_DIRECT) ###"
print_header
run_case nfs41_1M_1job   "$MNT_V4" 1 1M 2G 1 libaio
run_case nfsv3_1M_1job   "$MNT_V3" 1 1M 2G 1 libaio
[ "$CRASHED" -eq 1 ] && { echo "!! aborting matrix: ganesha crashed"; exit 2; }

echo
echo "### Phase 2: block-size sweep (NFSv4.1, O_DIRECT, 1 job) ###"
print_header
run_case nfs41_128k_1job "$MNT_V4" 1 128k 2G 1 libaio
run_case nfs41_256k_1job "$MNT_V4" 1 256k 2G 1 libaio
run_case nfs41_512k_1job "$MNT_V4" 1 512k 2G 1 libaio

echo
echo "### Phase 3: wsize negotiation (NFSv4.1, bs matches wsize, O_DIRECT) ###"
print_header
for ws in 262144 524288 1048576; do
  lazy_unmount "$MNT_V4"
  sudo mkdir -p "$MNT_V4"
  sudo mount -t nfs -o "vers=4.1,proto=tcp,rsize=1048576,wsize=$ws" "$SRV:/seaweedfs" "$MNT_V4" 2>/dev/null
  case $ws in
    262144) bs=256k ;;
    524288) bs=512k ;;
    *)      bs=1M ;;
  esac
  run_case "nfs41_ws${ws}_${bs}" "$MNT_V4" 1 "$bs" 2G 1 libaio
done

echo
echo "### Phase 4: concurrency scaling (NFSv4.1, bs=1M, O_DIRECT) ###"
lazy_unmount "$MNT_V4"; sudo mkdir -p "$MNT_V4"
sudo mount -t nfs -o "vers=4.1,proto=tcp,rsize=1048576,wsize=1048576" "$SRV:/seaweedfs" "$MNT_V4" 2>/dev/null
print_header
run_case nfs41_1M_2job "$MNT_V4" 2 1M 1G 1 libaio
run_case nfs41_1M_4job "$MNT_V4" 4 1M 1G 1 libaio
run_case nfs41_1M_8job "$MNT_V4" 8 1M 512M 1 libaio

echo
echo "### Phase 5: persistence semantics (NFSv4.1, bs=1M, 1 job) ###"
print_header
run_case nfs41_buffered  "$MNT_V4" 1 1M 2G 0 libaio
run_case nfs41_odirect   "$MNT_V4" 1 1M 2G 1 libaio
run_case nfs41_fdatasync "$MNT_V4" 1 1M 1G 0 psync fdatasync=1

echo
echo "### Phase 6: FUSE-layer reference (same shapes, no NFS, no Ganesha) ###"
print_header
run_case fuse_1M_odirect   "$FUSE_MNT" 1 1M 2G 1 libaio
run_case fuse_1M_buffered  "$FUSE_MNT" 1 1M 2G 0 libaio
run_case fuse_1M_4job      "$FUSE_MNT" 4 1M 1G 1 libaio

echo
echo "### Phase 7: raw NVMe reference (no FUSE, no NFS) ###"
mkdir -p /home/ys1000/seaweedfs/scratch
print_header
run_case raw_1M_odirect /home/ys1000/seaweedfs/scratch 1 1M 2G 1 libaio
run_case raw_1M_buffered /home/ys1000/seaweedfs/scratch 1 1M 2G 0 libaio

echo
echo "### cleanup ###"
lazy_unmount "$MNT_V3"
rm -f /tmp/fio-*.fio /tmp/fio-*.out /tmp/mb.txt /tmp/ma.txt
echo "CSV: $CSV"
echo "done: $(date -Is)"
