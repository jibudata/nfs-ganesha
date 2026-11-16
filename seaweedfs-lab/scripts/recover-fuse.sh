#!/bin/bash
# =====================================================================
# Recover a wedged SeaweedFS FUSE mount and PROVE it works.
#
# A wedge looks like this:
#   * NFS write returns success, the file has the right size
#   * but the filer has no entry for it and the volume .dat files do not grow
#   * direct FUSE writes to the same mount still work
# The FUSE daemon has accepted the buffered writes into its RAM write
# buffer but never commits them (chunks -> volume server -> filer).
#
# Recovery: lazy umount -> wait until it leaves /proc/mounts -> restart the
# mount service -> restart Ganesha -> verify with a REAL write whose byte
# delta is measured on the volume server's .dat files.
# =====================================================================
set -uo pipefail

# cluster: <tag> <fuse mount dir> <data dir> <mount service> <ganesha pseudo> [restart cmd]
#
# The last field is the command that brings the mount back.  It is a systemd
# unit for the bare-metal clusters; the containerised arm's FUSE gateway is
# not a unit at all, it is scripts/docker-fuse-mount.sh.
CLUSTERS=(
  "A|/home/ys1000/seaweedfs/mnt|/home/ys1000/seaweedfs/data|seaweedfs-mount|seaweedfs"
  "B|/home/ys1000/seaweedfs-hdd/mnt|/home/ys1000/seaweedfs-hdd/data|seaweedfs-mount-b|seaweedfs-hdd"
  "A2|/home/ys1000/seaweedfs/mnt-nvme-fresh|/home/ys1000/seaweedfs/data-nvme-fresh|seaweedfs-mount-nvme-fresh|seaweedfs-nvme-fresh"
  "DOCKER|/home/ys1000/seaweedfs/mnt-docker|/home/ys1000/seaweedfs/docker-data|-|seaweedfs-docker|bash /home/ys1000/seaweedfs/scripts/docker-fuse-mount.sh up"
)

volbytes() { find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%d\n", s+0}'; }
is_mounted() { grep -q " $1 " /proc/mounts; }

echo "############ 1) detach + restart every FUSE mount ############"
for c in "${CLUSTERS[@]}"; do
  IFS='|' read -r tag mnt dd svc ps restart_cmd <<< "$c"
  [ -n "$restart_cmd" ] || restart_cmd="sudo systemctl restart $svc"
  echo "--- cluster $tag : $mnt ---"
  if is_mounted "$mnt"; then
    ( sudo umount -l "$mnt" >/dev/null 2>&1 ) &
    for i in $(seq 1 30); do
      is_mounted "$mnt" || break
      sleep 1
    done
    if is_mounted "$mnt"; then
      echo "    still in /proc/mounts after 30s -> forcing"
      ( sudo umount -l "$mnt" >/dev/null 2>&1 ) &
      sleep 3
    fi
  fi
  eval "$restart_cmd" >/dev/null 2>&1
  echo "    restarted $svc, waiting for the mount to come back"
  for i in $(seq 1 30); do
    sleep 1
    # liveness = a real stat, not a /proc/mounts lookup
    if ls "$mnt" >/dev/null 2>&1; then echo "    mount is live after ${i}s"; break; fi
  done
done

echo
echo "############ 2) restart Ganesha so it re-resolves every export ############"
sudo systemctl restart ganesha >/dev/null 2>&1
sleep 10
systemctl is-active ganesha
pgrep -x ganesha.nfsd | head -1

echo
echo "############ 3) verify each export really writes bytes to the volume server ############"
for c in "${CLUSTERS[@]}"; do
  IFS='|' read -r tag mnt dd svc ps restart_cmd <<< "$c"
  MP="/mnt/verify-$tag-$$"
  sudo mkdir -p "$MP"
  if ! timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
        "192.168.3.146:$ps" "$MP" >/dev/null 2>&1; then
    echo "  $tag ($ps): MOUNT FAILED"; continue
  fi
  d0=$(volbytes "$dd")
  dd if=/dev/urandom of="$MP/verify-$tag.bin" bs=1M count=32 conv=fsync >/dev/null 2>&1
  rc=$?
  sleep 5
  d1=$(volbytes "$dd")
  delta=$(( (d1 - d0)/1048576 ))
  printf "  %-3s pseudo=%-22s dd_rc=%s  volume .dat delta=%s MiB  %s\n" \
    "$tag" "$ps" "$rc" "$delta" \
    "$([ "$delta" -gt 0 ] && echo OK || echo '*** STILL WEDGED ***')"
  rm -f "$MP/verify-$tag.bin"
  ( sudo umount -l "$MP" >/dev/null 2>&1 ) &
  sleep 1
done

echo
echo "############ 4) same check for the local ext4 export ############"
MP="/mnt/verify-ext4-$$"
sudo mkdir -p "$MP"
if timeout 40 sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     "192.168.3.146:/local-ext4" "$MP" >/dev/null 2>&1; then
  dd if=/dev/urandom of="$MP/verify-ext4.bin" bs=1M count=32 conv=fsync >/dev/null 2>&1
  echo "  ext4 export: rc=$? size=$(stat -c %s "$MP/verify-ext4.bin" 2>/dev/null)"
  rm -f "$MP/verify-ext4.bin"
  ( sudo umount -l "$MP" >/dev/null 2>&1 ) &
fi
echo "done: $(date -Is)"
