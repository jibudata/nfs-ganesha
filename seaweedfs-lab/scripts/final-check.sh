#!/usr/bin/env bash
# Final: fdatasync persistence test (correct fio syntax) + cleanup + status
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

echo "=== kill stale fio processes from the cancelled run ==="
pkill -x fio 2>/dev/null && echo "  killed stale fio" || echo "  none running"
sleep 2

echo
echo "=== fdatasync-per-write (true persistence semantics) ==="
cat > /tmp/fio-sync.fio <<'EOF'
[global]
ioengine=psync
rw=write
bs=1M
size=2G
directory=/home/ys1000/seaweedfs/mnt
filename_format=sync.$jobnum

[sync]
numjobs=1
fdatasync=1
EOF
before=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
timeout 600 /usr/local/bin/fio /tmp/fio-sync.fio 2>&1 | grep -E "write: IOPS|^  WRITE:" | head -3
after=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
echo "  volume .dat growth: $(( (after - before) / 1024 / 1024 )) MiB (expected ~2048)"

echo
echo "=== plain buffered write for comparison (same size) ==="
cat > /tmp/fio-buf.fio <<'EOF'
[global]
ioengine=psync
rw=write
bs=1M
size=2G
directory=/home/ys1000/seaweedfs/mnt
filename_format=buf.$jobnum

[buf]
numjobs=1
EOF
before=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
timeout 600 /usr/local/bin/fio /tmp/fio-buf.fio 2>&1 | grep -E "write: IOPS|^  WRITE:" | head -3
after=$(cat "$SW_DATA_DIR"/*.dat 2>/dev/null | wc -c)
echo "  volume .dat growth: $(( (after - before) / 1024 / 1024 )) MiB (expected ~2048)"

echo
echo "=== cleanup mount artifacts ==="
for f in "$SW_MNT"/*.0 "$SW_MNT"/*.1 "$SW_MNT"/*.2 "$SW_MNT"/*.3 \
         "$SW_MNT"/*.4 "$SW_MNT"/*.5 "$SW_MNT"/*.6 "$SW_MNT"/*.7; do
  [ -e "$f" ] && rm -f "$f"
done
rm -f /tmp/fio-sync.fio /tmp/fio-buf.fio
ls -la "$SW_MNT"

echo
echo "=== final status ==="
/home/ys1000/seaweedfs/scripts/status.sh 2>&1 | head -45
