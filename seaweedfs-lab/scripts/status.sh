#!/usr/bin/env bash
# SeaweedFS stack status + FUSE layer inspection
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env
# Shared helpers: is_mounted. See LAB-CONVENTIONS.md R2.
. "$(dirname "$0")/lib-nfslab.sh"

echo "================ PROCESSES ================"
ps -eo pid,pcpu,rss,etime,args | grep -E "[w]eed (master|server|filer|mount)" | sed 's/  */ /g'

echo
echo "================ LISTEN PORTS ================"
ss -tlnp 2>/dev/null | grep "weed" | sed 's/  */ /g'

echo
echo "================ MOUNT ================"
if is_mounted "$SW_MNT"; then
  findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS "$SW_MNT" | tr ',' '\n' | sed 's/^/  /'
else
  echo "  NOT MOUNTED at $SW_MNT"
fi

echo
echo "================ FUSE CONNECTION PARAMS ================"
# the seaweedfs mount is the connection whose max_background matches
# $SW_MAX_BACKGROUND; other fuse mounts on the host are unrelated
for d in /sys/fs/fuse/connections/*; do
  [ -d "$d" ] || continue
  mb=$(cat "$d/max_background" 2>/dev/null || echo "?")
  ct=$(cat "$d/congestion_threshold" 2>/dev/null || echo "?")
  wt=$(cat "$d/waiting" 2>/dev/null || echo "?")
  tag=" "
  [ "$mb" = "$SW_MAX_BACKGROUND" ] && tag="*"
  printf "  %s conn=%-4s max_background=%-6s congestion_threshold=%-6s waiting=%s\n" \
    "$tag" "$(basename "$d")" "$mb" "$ct" "$wt"
done

echo
echo "================ CLUSTER STATUS ================"
curl -sS -m 10 "http://$SW_IP:$SW_MASTER_HTTP/cluster/status" 2>&1
echo
curl -sS -m 10 "http://$SW_IP:$SW_MASTER_HTTP/dir/status?pretty=y" 2>&1 | head -20

echo
echo "================ FILER ROOT ================"
curl -sS -m 10 -H "Accept: application/json" "http://$SW_IP:$SW_FILER_HTTP/?pretty=y" 2>&1 | head -30

echo
echo "================ STORAGE ================"
echo "  volume files:"
ls -l "$SW_DATA_DIR" 2>/dev/null | tail -n +2 | awk '{printf "    %-16s %10.2f MiB\n", $9, $5/1024/1024}' | head -12
printf "  disk avail blocks=%s block_size=%s\n" "$(stat -f -c %a "$SW_DATA_DIR")" "$(stat -f -c %S "$SW_DATA_DIR")"
printf "  cache dir usage: %s\n" "$(du -sh "$SW_CACHE_DIR" 2>/dev/null | cut -f1)"
