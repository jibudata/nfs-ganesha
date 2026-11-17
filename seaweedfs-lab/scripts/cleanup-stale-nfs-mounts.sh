#!/bin/bash
# =====================================================================
# cleanup-stale-nfs-mounts.sh
#
#   usage: bash cleanup-stale-nfs-mounts.sh [keep-mount-point ...]
#
# WHY THIS EXISTS
#
# The lab host is BOTH the NFS server and an NFS client: the benchmarks
# mount the server's own exports to drive them.  A leftover client mount
# from an earlier run is not harmless.  With `hard` mounts (and
# `timeo=600, retrans=2`) the client retries forever, and each retry is
# another NFS request for the server to answer:
#
#   nfs: server 192.168.3.146 not responding, still trying
#
# Eleven such mounts were left behind by a heal test on 2026-11-16.
# When the server got busy, the retries piled up, the host's load
# average went to 98 on 16 cores, and - this is the part that costs the
# most time - `ps` and `pgrep -f` STOPPED WORKING, because reading
# /proc/<pid>/cmdline needs mmap_lock in read mode and a wedged write
# path holds it in write mode.  A host that cannot be inspected is a
# host that cannot be debugged.
#
# The mounts this script removes are CLIENT mounts of this host's own
# exports.  The FUSE mounts and the exports themselves are untouched.
#
# Anything listed on the command line is kept - the comparison run keeps
# its three mounts while it is going.
# =====================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-nfslab.sh"

SELF=${SELF:-192.168.3.146}

keep=" $* "

echo "=== the NFS client mounts of this host ==="

# /proc/mounts is a table read: it never blocks, even when the mount
# underneath it is wedged.  Field 3 is the server, field 2 the mount
# point and field 1 the device ("host:/export").
nfs_mounts=$(awk -v self="$SELF" '$3 ~ /^nfs/ && index($1, self ":") == 1 { print $2 }' /proc/mounts)

if [ -z "$nfs_mounts" ]; then
  echo "  none"
  exit 0
fi

gone=0
kept=0
failed=0
for m in $nfs_mounts; do
  case "$keep" in
    *" $m "*) echo "  keep   $m"; kept=$((kept+1)); continue ;;
  esac
  # The lazy unmount detaches the tree immediately; a synchronous unmount
  # of a wedged client sits in D state and cannot be killed, so it is
  # never the right choice here.
  if sudo umount -l "$m" >/dev/null 2>&1; then
    echo "  gone   $m"
    gone=$((gone+1))
  else
    echo "  STUCK  $m"
    failed=$((failed+1))
  fi
done

# Give the kernel a moment to drop the detached trees, then report.
sleep 2
left=$(awk -v self="$SELF" '$3 ~ /^nfs/ && index($1, self ":") == 1 { print $2 }' /proc/mounts)
echo
echo "  detached: $gone   kept: $kept   stuck: $failed"
if [ -n "$left" ]; then
  echo "  still mounted:"
  for m in $left; do echo "    $m"; done
else
  echo "  no self-mounts left"
fi
echo "  load: $(cat /proc/loadavg)"
