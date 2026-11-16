#!/bin/bash
# The production-recommended pattern: buffered NFS writes for throughput,
# then ONE fsync at the end for durability.  Measures the total elapsed time
# including that final flush (i.e. the real durability cost).
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

MNT=/mnt/ganesha-test
sudo mkdir -p "$MNT"
lazy_unmount "$MNT"
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/seaweedfs "$MNT" || { echo "MOUNT FAILED"; exit 1; }

run() { # <label> <size> <extra fio opts...>
  local label=$1 size=$2; shift 2
  local jf=/tmp/pat-$label.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=1M\ndirect=0\niodepth=16\nsize=%s\n' "$size"
    printf 'directory=%s\n' "$MNT"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=1\n' "$label"
    for a in "$@"; do printf '%s\n' "$a"; done
  } > "$jf"

  local t0=$(date +%s.%N)
  /usr/local/bin/fio "$jf" > /tmp/pat-$label.out 2>&1
  local t1=$(date +%s.%N)
  local bw=$(grep -oE 'BW=[0-9.]+MiB/s' /tmp/pat-$label.out | head -1 | cut -d= -f2)
  local el=$(echo "$t1 - $t0" | bc)
  local eff=$(echo "scale=2; $size/1024/$el" | bc)

  printf '%-28s fioBW=%-9s total_elapsed=%-7ss effective=%s MiB/s\n' \
     "$label" "${bw:-?}" "$el" "$eff"

  # did the data actually reach the volume server?
  local d=$(du -sm /home/ys1000/seaweedfs/data 2>/dev/null | cut -f1)
  printf '    volume-server data dir: %s MiB\n' "$d"

  for f in "$MNT/$label".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
}

echo "=== buffered, no explicit sync (unsafe: data may sit in caches) ==="
run buffered_nosync_2G 2G

echo
echo "=== buffered + end_fsync=1 (one flush at the end = durable) ==="
run buffered_endsync_2G 2G end_fsync=1

echo
echo "=== buffered + end_fsync=1, 8 GiB (how does the flush cost scale?) ==="
run buffered_endsync_8G 8G end_fsync=1

echo
echo "=== O_DIRECT reference for the same 2 GiB ==="
cat > /tmp/pat-odirect.fio <<'EOF'
[global]
ioengine=libaio
rw=write
bs=1M
direct=1
iodepth=16
size=2G
directory=/mnt/ganesha-test
filename_format=odirect_ref.$jobnum

[odirect_ref]
numjobs=1
EOF
local_t0=$(date +%s.%N)
/usr/local/bin/fio /tmp/pat-odirect.fio > /tmp/pat-odirect.out 2>&1
local_t1=$(date +%s.%N)
printf 'odirect_ref_2G              fioBW=%-9s total_elapsed=%ss\n' \
  "$(grep -oE 'BW=[0-9.]+MiB/s' /tmp/pat-odirect.out | head -1 | cut -d= -f2)" \
  "$(echo "$local_t1 - $local_t0" | bc)"
for f in "$MNT/odirect_ref".*; do [ -e "$f" ] && rm -f "$f"; done

lazy_unmount "$MNT"
rm -f /tmp/pat-*.fio /tmp/pat-*.out
echo "PATTERN DONE"
