#!/bin/bash
# =====================================================================
# render-arm-compare.sh - turn the three-arm comparison CSV into a table.
#
#   usage: bash render-arm-compare.sh [csv]
#
# The comparison runs the same cases against three arms and ROTATES the
# arm order every round, so one pass per arm would compare the first arm
# against whatever the machine was doing in the last five minutes.  What
# is reported here is the MEDIAN over the rounds, with the spread, so a
# single unlucky round cannot decide the result.
#
# A case whose bytes did not land is VOID and is counted separately: its
# throughput is meaningless no matter how good it looks.  A void case is
# never folded into a median.
#
#   usage: bash render-arm-compare.sh [csv]
# =====================================================================
set -uo pipefail

CSV=${1:-/home/ys1000/seaweedfs/logs/arm-compare.csv}
[ -f "$CSV" ] || { echo "ERROR: $CSV is not there" >&2; exit 2; }

# case arm bw MiB/s ganesha_write_latency_ms cpu_s_per_GiB landed_MiB wrote_MiB void
awk -F, '
  NR == 1 { next }
  {
    bw = $6
    if (bw ~ /GiB\/s$/) { sub(/GiB\/s$/, "", bw); bw = bw * 1024 }
    else if (bw ~ /KiB\/s$/) { sub(/KiB\/s$/, "", bw); bw = bw / 1024 }
    else if (bw ~ /MiB\/s$/) { sub(/MiB\/s$/, "", bw) }
    else { bw = 0 }
    void = ($22 ~ /void=1/) ? 1 : 0
    printf "%s %s %.2f %s %s %s %s %d\n", $1, $2, bw, $9, $19, $12, $11, void
  }' "$CSV" | sort -k1,1 -k2,2 -k3,3n > /tmp/ac-sorted.txt

echo "| case | arm | BW median (MiB/s) | BW min..max | Ganesha WRITE lat (ms) | CPU-s/GiB | landed / wrote | voids |"
echo "|---|---|---|---|---|---|---|---|"

awk '
  function flush() {
    if (n == 0) return
    mid = int((n + 1) / 2)
    med = (n % 2) ? v[mid] : (v[mid] + v[mid+1]) / 2
    printf "| %s | %s | %.0f | %.0f..%.0f | %s | %s | %s MiB / %s MiB | %d |\n",
           case_, arm, med, v[1], v[n], lat[mid], cpu[mid], land[mid], wrote[mid], voids
    n = 0
  }
  {
    if (case_ != $1 || arm != $2) {
      flush()
      case_ = $1; arm = $2; n = 0; voids = 0
    }
    # A void case is COUNTED but not folded into the median: its throughput
    # is meaningless, and the file is sorted by bandwidth, so a void row
    # with a high number would land right next to the median and drag it
    # up.  The header of this file promises "a void case is never folded
    # into a median" - this is where that promise is kept.
    voids += $8
    if ($8 == 1) next
    n++
    v[n] = $3
    lat[n] = $4
    cpu[n] = $5
    land[n] = $6
    wrote[n] = $7
  }
  END { flush() }
' /tmp/ac-sorted.txt

echo
echo "CSV: $CSV"
echo
echo "A case is VOID when its bytes did not reach the volume server, when fio"
echo "reported an error, or when its exit status was not 0.  Void cases are"
echo "counted here and excluded from every median."
