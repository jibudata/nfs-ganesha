#!/bin/bash
# Decisive experiment: add a second export pointing at a LOCAL ext4 directory
# (no FUSE in the path) so the NFS+Ganesha layer can be measured independently
# of the SeaweedFS FUSE layer.
set -uo pipefail
# Shared helpers: lazy_unmount. See LAB-CONVENTIONS.md R3.
. "$(dirname "$0")/lib-nfslab.sh"

EXT4DIR=/home/ys1000/ganesha-local-ext4
CONF=/etc/ganesha/ganesha.conf
MNT=/mnt/ganesha-local

mkdir -p "$EXT4DIR"

if ! grep -q "ganesha-local-ext4" "$CONF"; then
  cat > /tmp/ext4-export.conf <<'EOF'

# --- lab-only control export: plain local ext4, NO FUSE in the path ---
# Used to separate "NFS + Ganesha" cost from "FUSE/SeaweedFS" cost.
EXPORT {
    Export_Id = 2;
    Path = "/home/ys1000/ganesha-local-ext4";
    Pseudo = "/local-ext4";
    Access_Type = RW;
    Squash = Root_Squash;
    Protocols = 4, 3;
    Transports = TCP;
    SecType = sys, none;
    MaxWrite = 1048576;
    MaxRead  = 1048576;
    PrefWrite = 1048576;
    PrefRead  = 1048576;
    PrefReaddir = 1048576;
    FSAL {
        Name = VFS;
    }
}
EOF
  sudo sh -c "cat /tmp/ext4-export.conf >> $CONF"
  echo "export appended"
else
  echo "export already present"
fi

sudo systemctl restart ganesha
sleep 8
echo "ganesha: $(systemctl show ganesha -p ActiveState -p NRestarts --value | tr '\n' ' ')"

sudo mkdir -p "$MNT"
lazy_unmount "$MNT"
sudo mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
     192.168.3.146:/local-ext4 "$MNT" || { echo "MOUNT FAILED"; exit 1; }
mount | grep ganesha-local

run() { # <label> <numjobs> <bs> <size> <direct>
  local label=$1 nj=$2 bs=$3 size=$4 direct=$5
  local jf=/tmp/lab-$label.fio
  {
    printf '[global]\n'
    printf 'ioengine=libaio\nrw=write\nbs=%s\ndirect=%s\niodepth=16\nsize=%s\n' "$bs" "$direct" "$size"
    printf 'directory=%s\n' "$MNT"
    printf 'filename_format=%s.$jobnum\n' "$label"
    printf '\n[%s]\nnumjobs=%s\n' "$label" "$nj"
  } > "$jf"
  /usr/local/bin/fio "$jf" > /tmp/lab-$label.out 2>&1
  printf '%-24s ' "$label"
  grep -E 'WRITE: bw=' /tmp/lab-$label.out | sed 's/^ *//' | cut -c1-90
  grep -E 'clat \(|write: IOPS' /tmp/lab-$label.out | sed 's/^/    /'
  for f in "$MNT/$label".*; do [ -e "$f" ] && rm -f "$f"; done
  rm -f "$jf"
}

echo
echo "=== NFS(v4.1) -> Ganesha -> LOCAL EXT4 (no FUSE) ==="
run ext4_1M_1job_odirect 1 1M 2G 1
run ext4_1M_1job_buffered 1 1M 2G 0
run ext4_1M_8job_odirect 8 1M 512M 1

echo
echo "=== reference: same host, direct to the ext4 dir (no NFS, no Ganesha) ==="
/usr/local/bin/fio --name=rawlocal --rw=write --bs=1M --size=2G --direct=1 \
  --ioengine=libaio --iodepth=16 --filename="$EXT4DIR/rawlocal.bin" \
  > /tmp/lab-rawlocal.out 2>&1
grep -E 'WRITE: bw=|clat \(' /tmp/lab-rawlocal.out | sed 's/^/    /'
rm -f "$EXT4DIR/rawlocal.bin"

lazy_unmount "$MNT"
rm -f /tmp/lab-*.out /tmp/lab-*.fio
echo "EXT4 CONTROL DONE"
