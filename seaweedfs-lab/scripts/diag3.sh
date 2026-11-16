#!/bin/bash
set -uo pipefail
echo "=== load ==="; cat /proc/loadavg
echo
echo "=== fio progress ==="
for p in $(pgrep -x fio); do echo "  pid=$p etime=$(ps -o etime= -p $p 2>/dev/null | tr -d ' ')"; done
echo "  fio output:"; tail -3 /tmp/sus-fio.out 2>/dev/null | sed 's/^/    /'
echo
echo "=== device throughput ==="
timeout 12 iostat -dx 2 2 2>/dev/null | grep -E "Device|nvme0n1|sda " | head -8
echo
echo "=== top CPU ==="
ps -eo pid,stat,pcpu,rss,comm --sort=-pcpu 2>/dev/null | head -10
echo
echo "=== D-state count ==="
ps -eo stat 2>/dev/null | grep -c "^D" || true
echo
echo "=== weed states ==="
for p in $(pgrep -x weed); do
  cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -oE '(mount|server|filer|master)' | head -1)
  st=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)
  pc=$(ps -o pcpu= -p $p 2>/dev/null | tr -d ' ')
  dir=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -oE '\-dir=[^ ]*' | head -1)
  printf '  pid=%-7s %-7s state=%-2s cpu=%-6s %s\n' "$p" "$cl" "$st" "$pc" "$dir"
done
echo
echo "=== volume A2 log tail ==="
tail -6 /home/ys1000/seaweedfs/logs/seaweedfs-volume-nvme-fresh.service.log 2>/dev/null
echo "DIAG3 DONE"
