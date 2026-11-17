#!/bin/bash
# =====================================================================
# render-sustained.sh - CSV -> Markdown for the sustained matrix.
#
#   usage: bash render-sustained.sh [results/sustained-50g.csv]
#
# One table, case-major: every case a row, every arm a throughput cell.
# Void and skipped cases are PRINTED AS SUCH, never dropped - a matrix
# that quietly loses its failed cases is a matrix that reports fiction.
# The od_urand1M row sits next to od_bs1M on purpose: same shape, same
# engine, same iodepth - the only difference is where the random bytes
# came from (kernel urandom vs fio's PRNG), so the two cells together
# answer whether the ORIGIN of the data ever mattered.
#
# Each cell comes from the row that exists - no medians, no column
# cross-talk: the sustained matrix is one round per case, 50 GiB each,
# which is the entire point of it.
# =====================================================================
set -uo pipefail

CSV=${1:-/home/ys1000/seaweedfs/logs/sustained-50g.csv}
[ -r "$CSV" ] || { echo "no such CSV: $CSV" >&2; exit 2; }

echo "# Sustained write matrix - $(basename "$CSV")"
echo
echo '| case | bare MiB/s | docker MiB/s | k8s MiB/s | clat ms b/d/k | landed MiB b/d/k | notes |'
echo '|---|---|---|---|---|---|---|'

awk -F, '
NR > 1 {
  if (!seen[$2]++) order[++n] = $2
  bw[$1 SUBSEP $2] = $6
  clat[$1 SUBSEP $2] = $7
  wrote[$1 SUBSEP $2] = $10
  landed[$1 SUBSEP $2] = $11
  void[$1 SUBSEP $2] = $22
  extra[$1 SUBSEP $2] = $24
}
function norm(v,  x) {
  if (v ~ /GiB\/s$/) { x = v; sub(/GiB\/s$/, "", x); return sprintf("%.0f", x * 1024) }
  if (v ~ /MiB\/s$/) { x = v; sub(/MiB\/s$/, "", x); return sprintf("%.0f", x) }
  if (v ~ /KiB\/s$/) { x = v; sub(/KiB\/s$/, "", x); return sprintf("%.0f", x / 1024) }
  return v
}
function armname(i) { return i == 1 ? "bare" : (i == 2 ? "docker" : "k8s") }
END {
  for (i = 1; i <= n; i++) {
    c = order[i]
    line = "| " c " |"
    note = ""
    for (a = 1; a <= 3; a++) {
      k = armname(a) SUBSEP c
      if (k in bw) {
        cell = norm(bw[k])
        if (void[k] == "void=1") { cell = "VOID(" cell ")"; note = note " " armname(a) ":void" }
        if (extra[k] != "") note = note " " armname(a) ":" extra[k]
        line = line " " cell " |"
      } else {
        line = line " - |"
      }
    }
    line = line " "
    for (a = 1; a <= 3; a++) {
      k = armname(a) SUBSEP c
      line = line ((k in clat && clat[k] != "") ? clat[k] : "-") (a < 3 ? "/" : " |")
    }
    line = line " "
    for (a = 1; a <= 3; a++) {
      k = armname(a) SUBSEP c
      if (k in landed)
        line = line landed[k] "/" ((k in wrote) ? wrote[k] : "?") (a < 3 ? "/" : " |")
      else
        line = line "-" (a < 3 ? "/" : " |")
    }
    printf "%s %s |\n", line, note
  }
}' "$CSV"

echo
echo 'landed column: landed/wrote MiB per arm (bare/docker/k8s).'
echo 'A VOID cell proves nothing and is excluded from every conclusion.'
