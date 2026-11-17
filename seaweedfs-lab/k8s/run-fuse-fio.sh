#!/bin/bash
# =====================================================================
# run-fuse-fio.sh - runs INSIDE the Kubernetes pod.
#
# This is the fourth shape of the comparison: the SeaweedFS storage
# plane is in the cluster, the FUSE gateway is in a pod, and fio writes
# to that mount from the same pod.  No NFS and no Ganesha are involved:
# what this measures is the storage path alone, from inside the cluster.
#
# Why the FUSE mount can live in the pod here, when it could not live in
# the container in the Docker arm: in the Docker arm the mount had to
# REACH THE HOST (Ganesha runs on the host), and a mount created in a
# container does not propagate back to the host - it lands in another
# peer group.  Here nothing has to reach the host: the mount and the
# fio that writes to it are in the same pod, so the mount never has to
# cross a mount namespace at all.
#
# The address the mount dials for the filer is the LoadBalancer address
# (172.18.255.52:19344), and the address it fetches CHUNKS from is the
# one the master recorded for the volume server (172.18.255.51:19342).
# Both are reachable from a pod: verified with k8s/net-probe.yaml.
#
# The flags are the bare-metal ones from scripts/mount.sh, and the fio in
# the image is the Ubuntu 24.04 package - the same upstream version as
# the host's local build (3.36), which is what makes the numbers
# comparable with the other arms and not with "some fio".
#
# The output is one RESULT line, which scripts/k8s-fuse-fio.sh parses.
# =====================================================================
set -uo pipefail

SW_BIN=${SW_BIN:-/usr/local/bin/weed}
FIO=${FIO:-/usr/bin/fio}
FILER=${FILER:?FILER is required}
CASE=${CASE:?CASE is required}
BS=${BS:-1M}
SIZE=${SIZE:-128M}
DIRECT=${DIRECT:-0}
NJOBS=${NJOBS:-1}
MNT=${MNT:-/mnt}
CACHE=${CACHE:-/cache}
LOGDIR=${LOGDIR:-/work/log}

mkdir -p "$LOGDIR" "$CACHE" "$MNT"

log() { echo "[$(date +%T)] $*"; }

# ---- 1. the FUSE mount --------------------------------------------------
log "mounting $MNT from the filer at $FILER"
"$SW_BIN" mount \
  -filer="$FILER" \
  -dir="$MNT" \
  -volumeName=seaweedfs-k8s-inpod \
  -allowOthers=true \
  -defaultPermissions=true \
  -umask=022 \
  -cacheDir="$CACHE" \
  -cacheCapacityMB=128 \
  -cacheMetaTtlSec=60 \
  -chunkSizeLimitMB=2 \
  -writeBufferSizeMB=4096 \
  -concurrentWriters=128 \
  -concurrentReaders=128 \
  -metadataFlushSeconds=120 \
  -fuse.maxBackground=128 \
  -fuse.congestionThreshold=0 \
  -df.logical \
  -dlm > "$LOGDIR/mount.log" 2>&1 &
MOUNT_PID=$!

# "is it mounted" must check the FILESYSTEM TYPE, not just that the path
# is in /proc/mounts.
mounted=0
for i in $(seq 1 60); do
  if awk -v p="$MNT" '$2 == p && $3 == "fuse.seaweedfs" { found = 1 } END { exit !found }' /proc/mounts; then
    mounted=1
    break
  fi
  sleep 1
done
if [ "$mounted" != "1" ]; then
  log "FATAL: the FUSE mount did not come up"
  tail -30 "$LOGDIR/mount.log"
  echo "RESULT case=$CASE status=MOUNT_FAILED"
  exit 1
fi
log "the mount is live after ${i}s"
awk -v p="$MNT" '$2 == p { print "  " $0 }' /proc/mounts

# ---- 2. the write -------------------------------------------------------
JF=$LOGDIR/job.fio
{
  printf '[global]\n'
  printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\nfallocate=none\n' \
         "$BS" "$DIRECT" "$SIZE"
  # Non-zero data: SeaweedFS stores an all-zero chunk as a reference only,
  # so a zero-filled probe would not move the .dat size at all and the
  # landing check would be a false negative.
  printf 'scramble_buffers=1\n'
  printf 'directory=%s\n' "$MNT"
  printf 'filename_format=inpod-%s-%s.$jobnum\n' "$(hostname)" "$CASE"
  printf '\n[%s]\nnumjobs=%s\n' "$CASE" "$NJOBS"
} > "$JF"

log "running fio: bs=$BS size=$SIZE direct=$DIRECT numjobs=$NJOBS"
t0=$(date +%s.%N)
timeout 900 "$FIO" "$JF" > "$LOGDIR/fio.out" 2>&1
rc=$?
t1=$(date +%s.%N)
el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')

if [ "$rc" != "0" ]; then
  log "FATAL: fio exited with $rc"
  tail -30 "$LOGDIR/fio.out"
  echo "RESULT case=$CASE status=FIO_FAILED rc=$rc"
  exit 1
fi

# ---- 3. the numbers -----------------------------------------------------
# "bw=" appears once per job and once for the group summary; the group
# line is the one with the uppercase "WRITE:" prefix, so take that one.
bw=$(grep -oE 'WRITE: bw=[0-9.]+[KMG]iB/s' "$LOGDIR/fio.out" | tail -1 | cut -d= -f2)
[ -z "$bw" ] && bw=$(grep -oE 'bw=[0-9.]+[KMG]iB/s' "$LOGDIR/fio.out" | tail -1 | cut -d= -f2)

# The completion latency, NORMALISED TO MILLISECONDS.
#
# fio picks the unit from the magnitude, and the unit is printed in the
# section header: "clat (usec):".  Stripping the header with tr -d is
# wrong - tr deletes every character in the set, so "clat (usec):" comes
# out as "use", not "usec", and a reader cannot tell usec from msec.
# Take the unit out of the parentheses instead, and convert, so the CSV
# has one unit in it whatever fio decided.
cunit=$(grep -oE 'clat \((msec|usec|nsec)\)' "$LOGDIR/fio.out" | head -1 | grep -oE '(msec|usec|nsec)')
clat_raw=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' "$LOGDIR/fio.out" \
           | grep -oE 'avg=[0-9.]+' | head -1 | cut -d= -f2)
case "$cunit" in
  usec) clat=$(awk -v x="${clat_raw:-0}" 'BEGIN{printf "%.3f", x/1000}') ;;
  nsec) clat=$(awk -v x="${clat_raw:-0}" 'BEGIN{printf "%.3f", x/1000000}') ;;
  *)    clat=$(awk -v x="${clat_raw:-0}" 'BEGIN{printf "%.3f", x}') ;;
esac
cunit=ms
err=$(grep -oE 'err= *[0-9]+' "$LOGDIR/fio.out" | grep -oE '[0-9]+' | awk '{s+=$1} END{printf "%d", s+0}')
iob=$(grep -oE 'io=[0-9.]+[KMG]iB' "$LOGDIR/fio.out" | tail -1 | cut -d= -f2)
mib=0
case "$iob" in
  *KiB) mib=$(awk -v x="${iob%KiB}" 'BEGIN{printf "%d", x/1024}') ;;
  *MiB) mib=$(awk -v x="${iob%MiB}" 'BEGIN{printf "%d", x}') ;;
  *GiB) mib=$(awk -v x="${iob%GiB}" 'BEGIN{printf "%d", x*1024}') ;;
esac

log "bw=$bw clat=$clat$cunit elapsed=${el}s wrote=${mib}MiB"

# ---- 4. the report ------------------------------------------------------
# The landing delta is measured on the HOST (scripts/k8s-fuse-fio.sh), from
# inside the volume pod: the pod that writes cannot see the volume
# server's data directory.
#
# The field is called bw_agg because it IS the group aggregate: the
# selection happens here, where fio's output is.  The host only reads the
# value.
echo "RESULT case=$CASE status=OK bw_agg=${bw:-0} clat=${clat:-0} cunit=${cunit:-ms} elapsed=$el wrote_mib=$mib err=$err rc=$rc"

# Keep the mount up for a moment so the chunk upload can finish, then let
# the pod go: the volume server has the data, and the host measures it.
sleep 5
kill "$MOUNT_PID" 2>/dev/null
wait "$MOUNT_PID" 2>/dev/null
log "done"
