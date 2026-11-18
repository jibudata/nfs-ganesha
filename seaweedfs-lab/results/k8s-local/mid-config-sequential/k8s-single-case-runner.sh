#!/bin/bash
# Strict single-case runner: ONE fio, complete, stop, cleanup.
# usage: k8s-single-case.sh <name> <size> [extra fio opts...]
set -euo pipefail
NAME=${1:?usage: k8s-single-case.sh <name> <size> [extra-fio-opts]}; shift
SIZE=${1:?missing size}; shift
MNT=/mnt/ganesha-k8svm
PORT=32049
LAND_WAIT=300
FIO_TIMEOUT=1800
ART=$HOME/k8s-seq/$NAME
# 0) protocol: never overlap
if pgrep -x fio >/dev/null 2>&1; then echo "ERROR: another fio is running - refusing" >&2; exit 9; fi
# 1) fresh mount
sudo umount -l $MNT 2>/dev/null || true
rmdir $MNT 2>/dev/null || true
mkdir -p $MNT
sudo mount -t nfs -o "vers=4.1,proto=tcp,port=$PORT,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2" "127.0.0.1:/seaweedfs" $MNT
mkdir -p $MNT/fio
chmod 0777 $MNT/fio 2>/dev/null || true
rm -f $MNT/fio/* 2>/dev/null || true
# 2) datsize via node container (mawk-safe)
datsize() {
  sudo docker exec ganesha-fuse-ci-control-plane sh -c 'find /var/local-path-provisioner/pvc-*_seaweedfs_vol-seaweedfs-volume-0 -name "*.dat" -printf "%s\n" 2>/dev/null' | awk '{ s += $1 } END { printf "%.0f", s + 0 }'
}
# 3) single fio
mkdir -p $ART
cat > $ART/$NAME.fio <<EOJ
[global]
ioengine=libaio
rw=write
bs=1M
direct=0
iodepth=16
size=$SIZE
fallocate=none
end_fsync=0
scramble_buffers=1
directory=$MNT/fio
filename_format=$NAME.\$jobnum
group_reporting=1
[$NAME]
numjobs=1
$*
EOJ
echo "--- $NAME (size=$SIZE, opts: $*) start $(date -Is)"
before=$(datsize)
rc=0
timeout $FIO_TIMEOUT fio $ART/$NAME.fio > $ART/$NAME.fio.out 2>&1 || rc=$?
tail -3 $ART/$NAME.fio.out | grep -vE "^\s*$" | head -3
[ $rc -eq 0 ] || { echo "ERROR: fio failed rc=$rc"; exit $rc; }
# 4) landing settle (bounded)
expected=$(( $(numfmt --from=iec "$SIZE") ))
wait=0
after=$(datsize)
while [ "$((after - before))" -lt "$expected" ] && [ "$wait" -lt "$LAND_WAIT" ]; do
  sleep 5; wait=$((wait + 5)); after=$(datsize)
done
delta=$((after - before))
bw=$(grep -E '^[[:space:]]*WRITE:[[:space:]]*bw=' $ART/$NAME.fio.out | tail -1 | sed -E 's/.*bw=([^, ]+).*/\1/' || true)
echo "$NAME: bw=${bw:-?} written=$expected landed_delta=$delta rc=0"
printf '%s,%s,%s,%s,%s\n' "$NAME" "${bw:-unknown}" "$expected" "$delta" "$rc" >> $HOME/k8s-seq/results.csv
# 5) cleanup case data
rm -f $MNT/fio/$NAME.* 2>/dev/null || true
echo "--- $NAME done; test file removed"
