#!/usr/bin/env bash
# Render the raw bench-write-io.csv into a Markdown report table.
# Usage: render-results.sh <bench-write-io.csv> [out.md]
set -uo pipefail

CSV=${1:-/home/ys1000/seaweedfs/logs/bench-write-io.csv}
OUT=${2:-/home/ys1000/seaweedfs/logs/bench-write-io.md}

[ -r "$CSV" ] || { echo "cannot read $CSV"; exit 1; }

{
  echo "# NFS-Ganesha V15.9 → FUSE (SeaweedFS) Write I/O Matrix"
  echo
  echo "Host: ys1000@192.168.3.146 (Ubuntu 24.04, 16 vCPU, NVMe /dev/nvme0n1p3)"
  echo "Chain: NFS client → ganesha.nfsd (FSAL_VFS) → fuse.seaweedfs → weed filer → weed volume → NVMe"
  echo "Client and server are on the SAME host; NFS traffic uses the local br0 address"
  echo "and never crosses the 1 GbE physical NIC."
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "| case | MiB/s | IOPS | io_err | avg WRITE lat (ms) | rpc/s | WRITE ops | ganesha CPU (s) | weed mount CPU (s) | .dat delta (MiB) |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  tail -n +2 "$CSV" | while IFS=, read -r c bw iops err lat rps wop gcpu wcpu dmb rc; do
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$c" "$bw" "$iops" "$err" "$lat" "$rps" "$wop" "$gcpu" "$wcpu" "$dmb"
  done
  echo
  echo "Notes:"
  echo "- \`avg WRITE lat\` is Ganesha-side NFSv4 WRITE latency from Prometheus"
  echo "  (\`nfsv4__op_latency_sum / nfsv4__op_latency_count\`), in ms, summed over all status labels."
  echo "  It is 0 for the NFSv3 case because those metrics are NFSv4-only."
  echo "- \`.dat delta\` is the change in total volume-server \`.dat\` size over the case."
  echo "  It can be NEGATIVE: SeaweedFS reclaims/compacts volume files while a case runs,"
  echo "  so it is a rough 'data that reached the volume server' indicator, not a byte counter."
  echo "- \`ganesha CPU\` / \`weed mount CPU\` are process CPU seconds (utime+stime) consumed"
  echo "  during the case."
} > "$OUT"

echo "wrote $OUT"
cat "$OUT"
