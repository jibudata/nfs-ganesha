#!/usr/bin/env bash
# Faithful reproduction attempt: multiple stale NFS clients (2x v4.1 + 1x v3)
# reconnecting to a freshly restarted ganesha -> crash in the grace/reclaim path.
set -uo pipefail
# Shared helpers: lazy_unmount / is_mounted. See LAB-CONVENTIONS.md R2/R3.
. "$(dirname "$0")/lib-nfslab.sh"
SRV=192.168.3.146
A=/mnt/crash-a
B=/mnt/crash-b
C=/mnt/crash-c

pid() { systemctl show ganesha -p MainPID --value 2>/dev/null; }
cores() { ls -1 /var/lib/ganesha/core* 2>/dev/null | wc -l; }

echo "### setup: mount 2x NFSv4.1 + 1x NFSv3 clients ###"
for m in $A $B $C; do sudo mkdir -p $m; lazy_unmount $m; done
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 $SRV:/seaweedfs $A 2>&1 | head -1
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 $SRV:/seaweedfs $B 2>&1 | head -1
sudo mount -t nfs -o vers=3,proto=tcp $SRV:/home/ys1000/seaweedfs/mnt $C 2>&1 | head -1
echo "  mounted: $(mount | grep -c 'type nfs')"
sleep 3

echo
echo "### write on each client so all three have live state ###"
for m in $A $B $C; do
  dd if=/dev/urandom of=$m/state.bin bs=1M count=16 conv=fsync 2>&1 | tail -1
done
sleep 3
echo "  PID before restart: $(pid)"

echo
echo "### restart ganesha with all three clients still mounted ###"
sudo systemctl restart ganesha
for i in 1 2 3 4 5 6 7 8; do
  sleep 5
  echo "  t=$((i*5))s PID=$(pid) active=$(systemctl is-active ganesha) cores=$(cores)"
  # any client traffic after the restart
  for m in $A $B $C; do
    if is_mounted "$m"; then
      dd if=/dev/urandom of=$m/after.bin bs=1M count=4 conv=fsync >/dev/null 2>&1
    fi
  done
done

echo
echo "### cores ==="; ls -l /var/lib/ganesha/core* 2>/dev/null | head -3
echo "### journal ###"; sudo journalctl -u ganesha --no-pager -n 15 | tail -15
