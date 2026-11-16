#!/usr/bin/env bash
# Hypothesis: ganesha segfaults when previously-mounted NFS clients reconnect
# to a freshly restarted server instance (stale session / reclaim path).
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"
SRV=192.168.3.146
M=/mnt/ganesha-hyp

nr() { systemctl show ganesha -p NRestarts --value 2>/dev/null; }
pid() { systemctl show ganesha -p MainPID --value 2>/dev/null; }
state() { echo "    NRestarts=$(nr) MainPID=$(pid) active=$(systemctl is-active ganesha)"; }

echo "### inventory of currently mounted NFS clients ###"
mount | grep -E "type nfs" | sed "s/  */ /g"

echo
echo "### STEP 1: unmount ALL NFS clients, then restart ganesha ###"
for m in $(mount | grep "type nfs" | awk '{print $3}'); do
  echo "  unmount $m"
  lazy_unmount "$m"
done
sleep 3
echo "  remaining nfs mounts: $(mount | grep -c 'type nfs')"
before=$(nr)
sudo systemctl restart ganesha
sleep 20
after=$(nr)
echo "  NRestarts before=$before after=$after"
state
if [ "$after" -gt "$before" ]; then
  echo "  ==> CRASH REPRODUCED even with no clients mounted"
else
  echo "  ==> NO CRASH with no clients mounted"
fi

echo
echo "### STEP 2: mount a client, then restart ganesha WITH the client still mounted ###"
sudo mkdir -p $M
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 $SRV:/seaweedfs $M 2>&1 | head -1
sleep 3
state
before=$(nr)
echo "  restarting ganesha while the client stays mounted..."
sudo systemctl restart ganesha
sleep 20
after=$(nr)
echo "  NRestarts before=$before after=$after"
state
if [ "$after" -gt "$before" ]; then
  echo "  ==> CRASH REPRODUCED with a stale client mounted (hypothesis CONFIRMED)"
else
  echo "  ==> no crash with the client mounted"
fi

echo
echo "### cleanup ###"
lazy_unmount $M
sudo systemctl restart ganesha
sleep 10
state
echo "done"
