#!/bin/bash
# A dead FUSE mount stays registered in /proc/mounts but every access returns
# ENOTCONN (107).  `weed mount` then cannot mount again because the mount
# point is occupied, so systemd spins on "activating" forever.
# Fix: lazily detach the stale mount, wait until it leaves /proc/mounts, then
# restart the mount service and verify the path is actually usable.
set -uo pipefail

py_stat_ok() { python3 -c "
import os,sys
try:
    os.stat('$1'); print('ok')
except Exception as e:
    print('bad', e)
" 2>/dev/null; }

in_mounts() { grep -q " $1 " /proc/mounts; }

fix_fuse() { # <mountpoint> <service>
  local m=$1 svc=$2
  echo "=== $m ($svc) ==="
  if in_mounts "$m"; then
    local st; st=$(py_stat_ok "$m")
    case "$st" in
      ok*)
        echo "  mount is healthy, restarting service anyway"
        sudo systemctl restart "$svc" >/dev/null 2>&1
        ;;
      *)
        echo "  STALE mount (stat: $st) -> lazy detach"
        sudo fusermount3 -uz "$m" >/dev/null 2>&1
        sudo umount -l "$m" >/dev/null 2>&1
        for i in $(seq 1 15); do in_mounts "$m" || break; sleep 1; done
        if in_mounts "$m"; then
          echo "  still in /proc/mounts after lazy detach"
          timeout 10 sudo umount -f -l "$m" >/dev/null 2>&1
          sleep 2
        fi
        echo "  detached: $(in_mounts "$m" && echo NO || echo YES)"
        sudo systemctl restart "$svc" >/dev/null 2>&1
        ;;
    esac
  else
    sudo systemctl restart "$svc" >/dev/null 2>&1
  fi

  # wait until the path really works
  for i in $(seq 1 40); do
    st=$(py_stat_ok "$m")
    case "$st" in
      ok*) echo "  FUSE healthy after ${i}s"; return 0 ;;
    esac
    sleep 1
  done
  echo "  FUSE STILL BROKEN: $st"
  return 1
}

# stop the mount units first so they don't fight us
sudo systemctl stop seaweedfs-mount seaweedfs-mount-b seaweedfs-mount-nvme-fresh 2>/dev/null
sleep 3

fix_fuse /home/ys1000/seaweedfs/mnt            seaweedfs-mount
fix_fuse /home/ys1000/seaweedfs-hdd/mnt        seaweedfs-mount-b
fix_fuse /home/ys1000/seaweedfs/mnt-nvme-fresh seaweedfs-mount-nvme-fresh

echo
echo "=== FUSE mounts in /proc/mounts ==="
grep "fuse.seaweedfs" /proc/mounts
echo
echo "=== accessibility ==="
for m in /home/ys1000/seaweedfs/mnt /home/ys1000/seaweedfs-hdd/mnt /home/ys1000/seaweedfs/mnt-nvme-fresh; do
  printf '  %-44s %s\n' "$m" "$(py_stat_ok $m)"
done
echo
echo "=== service states ==="
for s in seaweedfs-mount seaweedfs-mount-b seaweedfs-mount-nvme-fresh; do
  printf '  %-32s %s\n' "$s" "$(systemctl is-active $s)"
done

echo
echo "=== restart ganesha so it picks up all four exports ==="
sudo systemctl restart ganesha
sleep 12
systemctl show ganesha -p ActiveState -p NRestarts --value | tr '\n' ' '
echo
showmount -e 192.168.3.146 2>/dev/null
echo "FUSE FIX DONE"
