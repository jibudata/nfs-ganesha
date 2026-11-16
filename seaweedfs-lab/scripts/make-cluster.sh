#!/bin/bash
# make-cluster.sh <tag> <data_dir> <cache_dir> <filerldb_dir> <master_dir>
#                 <mount_dir> <m_http> <m_grpc> <v_http> <v_grpc> <f_http> <f_grpc>
#
# Generates an IDENTICAL SeaweedFS cluster definition for a given tier.
# The ONLY intended difference between two invocations is the device that
# <data_dir> lives on.  Everything else (ports are passed in, filer metadata
# store, FUSE cache, tunables) is derived from the same template.
set -euo pipefail

TAG=$1; DATA=$2; CACHE=$3; FILERLDB=$4; MASTERDIR=$5; MNT=$6
M_HTTP=$7; M_GRPC=$8; V_HTTP=$9; V_GRPC=${10}; F_HTTP=${11}; F_GRPC=${12}
IP=127.0.0.1
SW_BIN=/usr/local/bin/weed
SW_ROOT=/home/ys1000/seaweedfs
SCRIPTS=$SW_ROOT/scripts

mkdir -p "$DATA" "$CACHE" "$FILERLDB" "$MASTERDIR" "$MNT"

cat > "$SCRIPTS/master-$TAG.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SW_BIN" master \\
  -ip=$IP -ip.bind=$IP \\
  -port=$M_HTTP -port.grpc=$M_GRPC \\
  -mdir="$MASTERDIR" \\
  -peers=none \\
  -telemetry=false \\
  -volumeSizeLimitMB=30720
EOF

cat > "$SCRIPTS/volume-$TAG.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SW_BIN" server \\
  -master=false -filer=false \\
  -ip=$IP -ip.bind=$IP \\
  -volume.port=$V_HTTP -volume.port.grpc=$V_GRPC \\
  -master.peers=$IP:$M_HTTP \\
  -master.port=$M_HTTP -master.port.grpc=$M_GRPC \\
  -dir="$DATA" \\
  -volume.max=8 \\
  -volume.readMode=local \\
  -dataCenter=dc1
EOF

cat > "$SCRIPTS/filer-$TAG.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SW_BIN" filer \\
  -ip=$IP -ip.bind=$IP \\
  -port=$F_HTTP -port.grpc=$F_GRPC \\
  -master=$IP:$M_HTTP \\
  -defaultStoreDir="$FILERLDB" \\
  -collection=""
EOF

cat > "$SCRIPTS/mount-$TAG.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$MNT" "$CACHE"
exec "$SW_BIN" mount \\
  -filer=$IP:$F_HTTP \\
  -dir="$MNT" \\
  -volumeName=seaweedfs-$TAG \\
  -allowOthers=true \\
  -defaultPermissions=true \\
  -umask=022 \\
  -cacheDir="$CACHE" \\
  -cacheCapacityMB=128 \\
  -cacheMetaTtlSec=60 \\
  -chunkSizeLimitMB=2 \\
  -writeBufferSizeMB=4096 \\
  -concurrentWriters=128 \\
  -concurrentReaders=128 \\
  -metadataFlushSeconds=120 \\
  -fuse.maxBackground=128 \\
  -fuse.congestionThreshold=0 \\
  -df.logical \\
  -dlm
EOF

cat > "$SCRIPTS/unmount-$TAG.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# Read the kernel mount table instead of calling mountpoint: mountpoint does a
# stat(2) on the path, which blocks in D state on a wedged mount, and this
# script is the systemd ExecStop.
is_mounted() {
  awk -v p="\$MNT" '\$2 == p { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}
if is_mounted; then
  # Bounded with a timeout rather than backgrounded: systemd's default
  # KillMode=control-group kills a backgrounded unmount the moment ExecStop
  # exits, so it would never finish.
  timeout 15 fusermount3 -u "\$MNT" 2>/dev/null \\
    || ( timeout 15 sudo umount -l "\$MNT" 2>/dev/null ) \\
    || true
fi
exit 0
EOF

chmod +x "$SCRIPTS"/*-$TAG.sh

unit() { # <unit-name> <script> <after/requires block>
  local name=$1 script=$2 dep=$3
  sudo tee "/etc/systemd/system/$name" >/dev/null <<EOF
[Unit]
Description=SeaweedFS ($TAG tier) $name
After=network-online.target
$dep

[Service]
Type=simple
User=ys1000
Group=ys1000
WorkingDirectory=$SW_ROOT
ExecStart=$SCRIPTS/$script
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=append:$SW_ROOT/logs/$name.log
StandardError=append:$SW_ROOT/logs/$name.log

[Install]
WantedBy=multi-user.target
EOF
}

unit "seaweedfs-master-$TAG.service" "master-$TAG.sh" ""
unit "seaweedfs-volume-$TAG.service" "volume-$TAG.sh" "After=seaweedfs-master-$TAG.service
Requires=seaweedfs-master-$TAG.service"
unit "seaweedfs-filer-$TAG.service"  "filer-$TAG.sh"  "After=seaweedfs-master-$TAG.service
Requires=seaweedfs-master-$TAG.service"
unit "seaweedfs-mount-$TAG.service"  "mount-$TAG.sh"  "After=seaweedfs-filer-$TAG.service seaweedfs-volume-$TAG.service
Requires=seaweedfs-filer-$TAG.service seaweedfs-volume-$TAG.service
BindsTo=seaweedfs-filer-$TAG.service"

# r10-exempt: this script CREATES a brand-new cluster. Its FUSE mount has no
# Ganesha export yet (the export is added to ganesha.conf afterwards and
# Ganesha is restarted then), so there is no dirfd that a restart could
# invalidate.
sudo systemctl daemon-reload
sudo systemctl enable "seaweedfs-master-$TAG" "seaweedfs-volume-$TAG" "seaweedfs-filer-$TAG" "seaweedfs-mount-$TAG" >/dev/null 2>&1

sudo systemctl start "seaweedfs-master-$TAG"; sleep 3
sudo systemctl start "seaweedfs-volume-$TAG"; sleep 3
sudo systemctl start "seaweedfs-filer-$TAG";  sleep 3
sudo systemctl start "seaweedfs-mount-$TAG";  sleep 6

echo "=== cluster $TAG ==="
systemctl is-active "seaweedfs-master-$TAG" "seaweedfs-volume-$TAG" "seaweedfs-filer-$TAG" "seaweedfs-mount-$TAG" | tr '\n' ' '
echo
mount | grep " $MNT " || echo "  FUSE mount missing"
df -h "$DATA" | tail -1
curl -sS -m 5 "http://$IP:$M_HTTP/cluster/status" || echo "  master not answering"
echo
