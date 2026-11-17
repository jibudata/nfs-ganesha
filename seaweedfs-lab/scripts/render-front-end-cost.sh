#!/bin/bash
# =====================================================================
# render-front-end-cost.sh - what does the NFS + Ganesha front end cost?
#
#   usage: bash render-front-end-cost.sh [three-arm-csv] [in-pod-csv]
#
# THE QUESTION
#
# The three-arm comparison measures "NFS client -> Ganesha -> FUSE -> filer
# -> volume server" three times: once with the storage plane on the bare
# metal, once in Docker, once in Kubernetes.  All three land in the same
# noise band, so the packaging is not what the write path spends its time
# on.
#
# The fourth shape measures the same storage path WITHOUT the front end:
#
#   fio -> FUSE (in a pod) -> filer (pod) -> volume server (pod)
#
# The Kubernetes arm and the in-pod arm talk to THE SAME Kubernetes
# storage plane and use the SAME FUSE gateway configuration; the only
# difference between them is the NFS + Ganesha front end in front.  So
#
#   cost of the front end  =  in-pod bandwidth  -  k8s-arm bandwidth
#
# and the ratio between the two is how much the front end costs as a
# fraction of the storage path.
#
# THE CAVEAT, STATED UP FRONT
#
# These are medians over separate runs, so the difference is a difference
# of two noisy numbers and not a controlled A/B.  The number is only
# worth reading when the two medians are far apart - a 6x difference is a
# finding, a 10% difference is not.
#
# A void case is excluded from every median: its throughput is
# meaningless no matter how good it looks.
# =====================================================================
set -uo pipefail

ARM_CSV=${1:-/home/ys1000/seaweedfs/logs/arm-compare.csv}
POD_CSV=${2:-/home/ys1000/seaweedfs/logs/k8s-fuse-fio.csv}

[ -f "$ARM_CSV" ] || { echo "ERROR: $ARM_CSV is not there" >&2; exit 2; }
[ -f "$POD_CSV" ] || { echo "ERROR: $POD_CSV is not there" >&2; exit 2; }

# --- normalise both CSVs to "arm case bandwidth_mib_s void" ---------------
# The Kubernetes arm of the three-arm comparison:
#   arm,case,bs,njobs,direct,BW,clat_avg_ms,clat_unit,ganesha_wlat_ms,...
awk -F, '
  NR == 1 { next }
  $1 != "k8s" { next }
  {
    bw = $6
    if (bw ~ /GiB\/s$/)      { sub(/GiB\/s$/, "", bw); bw = bw * 1024 }
    else if (bw ~ /KiB\/s$/) { sub(/KiB\/s$/, "", bw); bw = bw / 1024 }
    else if (bw ~ /MiB\/s$/) { sub(/MiB\/s$/, "", bw) }
    else                     { bw = 0 }
    void = ($22 ~ /void=1/) ? 1 : 0
    printf "k8s %s %.2f %d\n", $2, bw, void
  }' "$ARM_CSV" > /tmp/fec-k8s.txt

# The in-pod arm:
#   round,case,bs,njobs,direct,BW,clat_avg_ms,clat_unit,elapsed_s,...
awk -F, '
  NR == 1 { next }
  {
    bw = $6
    if (bw ~ /GiB\/s$/)      { sub(/GiB\/s$/, "", bw); bw = bw * 1024 }
    else if (bw ~ /KiB\/s$/) { sub(/KiB\/s$/, "", bw); bw = bw / 1024 }
    else if (bw ~ /MiB\/s$/) { sub(/MiB\/s$/, "", bw) }
    else                     { bw = 0 }
    void = ($12 ~ /void=1/) ? 1 : 0
    printf "inpod %s %.2f %d\n", $2, bw, void
  }' "$POD_CSV" > /tmp/fec-pod.txt

# --- median per (arm, case) ----------------------------------------------
# The rows of one (arm, case) group are NOT contiguous in the file - the
# sort is by arm first - so the groups are collected into arrays keyed by
# (arm, case) and emitted as "case arm median".
#
# The values are SORTED before the median is taken.  The rows arrive in
# round order, not in bandwidth order, and "the middle element" is not the
# median: three rounds of 1000, 692 and 1080 MiB/s have the element 692 in
# the middle, and the median is 1000.  Taking the middle element made the
# fourth form look 36% SLOWER than the NFS path, which is the opposite of
# the truth - the noise was being read as a result.
cat /tmp/fec-k8s.txt /tmp/fec-pod.txt | awk '
  function median(a, n,   i, j, t) {
    for (i = 2; i <= n; i++) {
      t = a[i]
      for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
      a[j + 1] = t
    }
    if (n % 2) return a[(n + 1) / 2]
    return (a[n / 2] + a[n / 2 + 1]) / 2
  }
  {
    key = $1 SUBSEP $2
    keys[key] = 1
    if ($4 == 1) { voids[key]++; next }
    n[key]++
    v[key, n[key]] = $3
  }
  END {
    for (key in keys) {
      split(key, p, SUBSEP)
      m = n[key] + 0
      if (m == 0) {
        # every round of this case was void: there is no median to quote
        printf "%s %s 0.000 0 %d\n", p[2], p[1], voids[key] + 0
        continue
      }
      for (i = 1; i <= m; i++) buf[i] = v[key, i]
      printf "%s %s %.2f %d %d\n", p[2], p[1], median(buf, m), m, voids[key] + 0
    }
  }' | sort -k1,1 -k2,2 > /tmp/fec-medians.txt

# --- join the two arms per case ------------------------------------------
echo "| case | k8s arm + NFS/Ganesha (MiB/s) | in-pod, no front end (MiB/s) | front-end cost |"
echo "|---|---|---|---|"

awk '
  {
    case_ = $1
    if ($2 == "k8s")   { kmed[case_] = $3; kn[case_] = $4; kv[case_] = $5 }
    if ($2 == "inpod") { pmed[case_] = $3; pn[case_] = $4; pv[case_] = $5 }
    if (!(case_ in seen)) { seen[case_] = 1; order[++n] = case_ }
  }
  END {
    for (i = 1; i <= n; i++) {
      c = order[i]
      km = (c in kmed) ? kmed[c] : 0
      pm = (c in pmed) ? pmed[c] : 0
      if (c in pmed && c in kmed && km > 0) {
        ratio = sprintf("%.2fx", pm / km)
        delta = sprintf("%.0f MiB/s (%.0f%% of the path)", pm - km, (pm - km) / pm * 100)
        printf "| %s | %.0f | %.0f | %s, %s |\n", c, km, pm, ratio, delta
      } else {
        printf "| %s | %s | %s | n/a |\n", c,
               (c in kmed) ? sprintf("%.0f", kmed[c]) : "-",
               (c in pmed) ? sprintf("%.0f", pmed[c]) : "-"
      }
    }
  }' /tmp/fec-medians.txt

echo
echo "arm CSV: $ARM_CSV"
echo "pod CSV: $POD_CSV"
echo
echo "The k8s arm and the in-pod arm write into the SAME Kubernetes storage"
echo "plane with the SAME FUSE gateway configuration.  The difference between"
echo "the two columns is the NFS + Ganesha front end and nothing else."
echo
echo "Void cases (bytes that did not reach the volume server) are excluded from"
echo "every median.  These are medians over separate runs, so read a large"
echo "difference as a finding and a small one as noise."
