#!/usr/bin/env bash
# Host-side fio comparison arm: NFS client -> Pod Ganesha -> Pod FUSE -> SeaweedFS.
set -euo pipefail

NS=${K8S_NS:-seaweedfs}
LB_IP=${GANESHA_LB_IP:-172.18.255.53}
NFS_HOST=${GANESHA_NFS_HOST:-$LB_IP}
NFS_PORT=${GANESHA_NFS_PORT:-2049}
MNT=${NFS_MNT:-/mnt/ganesha-k8s}
FIO=${FIO:-/usr/local/bin/fio}
SIZE=${SIZE:-512M}
CONC_SIZE=${CONC_SIZE:-128M}
DATSIZE=${DATSIZE:-$(dirname "$0")/k8s-volume-datsize.sh}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/ganesha-fuse-artifacts}
CSV=${CSV:-$ARTIFACT_DIR/results.csv}

[ -x "$FIO" ] || { echo "ERROR: fio executable not found: $FIO" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required for volume landing checks" >&2; exit 2; }
# /mnt is root-owned on the runner; the NFS mount below hides this directory.
sudo mkdir -p "$MNT"
mkdir -p "$ARTIFACT_DIR"

if [ "$NFS_PORT" = 2049 ]; then
  svc_ip=$(kubectl -n "$NS" get svc seaweedfs-ganesha-fuse -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ "$svc_ip" = "$LB_IP" ] || { echo "ERROR: service IP is '${svc_ip:-none}', expected $LB_IP" >&2; exit 1; }
else
  node_port=$(kubectl -n "$NS" get svc seaweedfs-ganesha-fuse -o jsonpath='{.spec.ports[?(@.name=="nfs")].nodePort}' 2>/dev/null || true)
  [ "$node_port" = "$NFS_PORT" ] || { echo "ERROR: NFS NodePort is '${node_port:-none}', expected $NFS_PORT" >&2; exit 1; }
fi

if ! awk -v m="$MNT" '$2 == m && $3 ~ /^nfs/ { found=1 } END { exit !found }' /proc/mounts; then
  sudo mount -t nfs -o "vers=4.1,proto=tcp,port=$NFS_PORT,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2" \
    "$NFS_HOST:/seaweedfs" "$MNT"
fi
awk -v m="$MNT" '$2 == m && $3 ~ /^nfs/ { found=1 } END { exit !found }' /proc/mounts \
  || { echo "ERROR: NFS mount is not present at $MNT" >&2; exit 1; }

# Everything a reviewer needs to reproduce a number lives in ARTIFACT_DIR:
# the raw fio output, the fio job file, the CSV and the mount/version context.
{
  echo "date: $(date -Is)"
  echo "fio: $("$FIO" --version 2>&1 | head -1)"
  echo "mount: $MNT (port $NFS_PORT)"
  echo "size: $SIZE; conc_size: $CONC_SIZE"
} > "$ARTIFACT_DIR/run-info.txt"
awk -v m="$MNT" '$2 == m' /proc/mounts > "$ARTIFACT_DIR/nfs-mounts.txt"

printf 'case,bw,bytes,landed_bytes,rc\n' > "$CSV"
run_case() {
  local name=$1 bs=$2 direct=$3 jobs=$4 size=$5
  local before after delta rc=0
  local out="$ARTIFACT_DIR/${name}.fio.out" job="$ARTIFACT_DIR/${name}.fio"
  before=$(bash "$DATSIZE")
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
directory=$MNT
filename_format=$name.\$jobnum
group_reporting=1
[$name]
numjobs=$jobs
EOF
  echo "=== $name: bs=$bs direct=$direct jobs=$jobs size/job=$size ==="
  timeout 1800 "$FIO" "$job" > "$out" 2>&1 || rc=$?
  cat "$out"
  [ "$rc" -eq 0 ] || { echo "ERROR: fio failed ($rc)" >&2; return 1; }
  local expected=$(( $(numfmt --from=iec "$size") * jobs ))
  local wait=0
  after=$(bash "$DATSIZE")
  while [ "$((after - before))" -lt "$((expected / 2))" ] && [ "$wait" -lt 60 ]; do
    sleep 1
    wait=$((wait + 1))
    after=$(bash "$DATSIZE")
  done
  delta=$((after - before))
  local bw
  bw=$(grep -E '^[[:space:]]*WRITE:[[:space:]]*bw=' "$out" | tail -1 | sed -E 's/.*bw=([^, ]+).*/\1/' || true)
  printf '%s,%s,%s,%s,%s\n' "$name" "${bw:-unknown}" "$expected" "$delta" "$rc" | tee -a "$CSV"
  if [ "$delta" -lt $((expected / 2)) ]; then
    echo "ERROR: only $delta bytes reached volume .dat files; case is invalid" >&2
    return 1
  fi
  rm -f "$MNT/$name".*
}

run_case buffered-1m 1M 0 1 "$SIZE"
run_case odirect-1m 1M 1 1 "$SIZE"
run_case odirect-8m 8M 1 1 "$SIZE"
run_case buffered-8job 1M 0 8 "$CONC_SIZE"

echo "CSV: $CSV"
echo "Raw fio output and job files: $ARTIFACT_DIR"
echo "NFS mount remains at $MNT; unmount manually after reviewing the run."
