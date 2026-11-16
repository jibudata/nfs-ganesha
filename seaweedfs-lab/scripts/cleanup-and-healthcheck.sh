#!/usr/bin/env bash
# Clean up benchmark artifacts from the SeaweedFS FUSE mount and verify health
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

echo "=== artifacts before cleanup ==="
ls -l "$SW_MNT" 2>/dev/null

for f in a.raw b1.raw b2 b2.0 b2.1 b2.2 b2.3 b3.raw b4.raw probe root-probe \
         testfile conc.* j*.raw; do
  [ -e "$SW_MNT/$f" ] && rm -rf "$SW_MNT/$f" && echo "  removed $f"
done
for f in a.raw; do
  [ -e "$SW_ROOT/scratch/$f" ] && rm -rf "$SW_ROOT/scratch/$f" && echo "  removed scratch/$f"
done

echo
echo "=== health check: fresh write must reach the volume server ==="
before=$(cat "$SW_DATA_DIR"/*.dat | wc -c)
dd if=/dev/urandom of="$SW_MNT/healthcheck" bs=1M count=256 conv=fsync 2>&1 | tail -1
sleep 8
after=$(cat "$SW_DATA_DIR"/*.dat | wc -c)
delta=$(( (after - before) / 1024 / 1024 ))
echo "  volume .dat growth: ${delta} MiB (expected ~256 MiB)"
if [ "$delta" -ge 200 ]; then
  echo "  HEALTHY: writes are reaching the volume server"
else
  echo "  WARNING: volume server did not receive the data"
fi
md5sum "$SW_MNT/healthcheck"
rm -f "$SW_MNT/healthcheck"

echo
echo "=== mount contents after cleanup ==="
ls -la "$SW_MNT"
