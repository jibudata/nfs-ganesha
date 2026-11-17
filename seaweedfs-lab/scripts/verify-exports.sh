#!/bin/bash
# verify-exports.sh - prove that every export really writes to the volume server.
#
# Writes real (non-zero) bytes through NFS and checks the volume .dat growth.
# Read-only with respect to the stack: it mounts, writes 32 MiB, verifies the
# landing and unmounts. It does NOT restart anything - use recover-fuse.sh for
# that. See LAB-CONVENTIONS.md R4/R4a/R10.
set -uo pipefail

# The size of a volume server's .dat files, in bytes, for a directory on
# THIS host.
size_dir() { # <dir>
  find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END{printf "%d", s+0}'
}

# check <pseudo> <size-command...>
#
# The size command is a command, not a directory, because the Kubernetes
# arm's data lives on the NODE and the node may itself be a container.
# Every arm is measured the same way - the APPARENT size of the .dat
# files, before and after the write - so the numbers are comparable.
check() {
  local pseudo=$1; shift
  local d0 d1 delta rc
  local m=/mnt/final-$$-$RANDOM
  sudo mkdir -p "$m"
  ( sudo umount -l "$m" >/dev/null 2>&1 ) &
  sleep 1
  if ! sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
       "192.168.3.146:$pseudo" "$m" 2>/dev/null; then
    printf "  %-22s MOUNT FAILED\n" "$pseudo"; return 1
  fi
  d0=$("$@")
  dd if=/dev/urandom of="$m/final-probe.bin" bs=1M count=32 conv=fsync >/dev/null 2>&1
  rc=$?
  sync; sleep 8
  d1=$("$@")
  delta=$(( (d1 - d0) / 1048576 ))
  if [ "$rc" = "0" ] && [ "$delta" -ge 32 ]; then
    printf "  %-22s dd_rc=%s  volume .dat delta=%s MiB  OK\n" "$pseudo" "$rc" "$delta"
  else
    printf "  %-22s dd_rc=%s  volume .dat delta=%s MiB  *** FAILED ***\n" "$pseudo" "$rc" "$delta"
  fi
  ( sudo umount -l "$m" >/dev/null 2>&1 ) &
}

echo "=== final landing check on every export ==="
check /seaweedfs            size_dir /home/ys1000/seaweedfs/data
check /seaweedfs-hdd        size_dir /home/ys1000/seaweedfs-hdd/data
check /seaweedfs-nvme-fresh size_dir /home/ys1000/seaweedfs/data-nvme-fresh
check /seaweedfs-docker     size_dir /home/ys1000/seaweedfs/docker-data

# The Kubernetes arm's data lives in a PersistentVolume on the NODE, and
# the node may itself be a container, so the size is measured from inside
# the volume pod rather than at a path on this host.  A path that does
# not exist here would report "no bytes landed" for a write that landed
# perfectly well - a false negative, which is the one thing this check
# must not produce.
K8S_DATSIZE=/home/ys1000/seaweedfs/scripts/k8s-volume-datsize.sh
if [ -x "$K8S_DATSIZE" ] && "$K8S_DATSIZE" >/dev/null 2>&1; then
  check /seaweedfs-k8s bash "$K8S_DATSIZE"
else
  printf "  %-22s SKIPPED (the Kubernetes arm is not deployed)\n" "/seaweedfs-k8s"
fi

echo "=== local ext4 control export ==="
m=/mnt/final-ext4-$$-$RANDOM
sudo mkdir -p "$m"
( sudo umount -l "$m" >/dev/null 2>&1 ) &
sleep 1
if sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/local-ext4 "$m" 2>/dev/null; then
  dd if=/dev/urandom of="$m/final-probe.bin" bs=1M count=32 conv=fsync >/dev/null 2>&1
  echo "  ext4 export: rc=$? size=$(stat -c %s "$m/final-probe.bin" 2>/dev/null)"
  ( sudo umount -l "$m" >/dev/null 2>&1 ) &
else
  echo "  ext4 export: MOUNT FAILED"
fi
echo "FINAL CHECK DONE"
