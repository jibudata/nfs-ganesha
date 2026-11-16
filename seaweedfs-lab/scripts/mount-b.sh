#!/usr/bin/env bash
set -euo pipefail
mkdir -p "/home/ys1000/seaweedfs-hdd/mnt" "/home/ys1000/seaweedfs/cache-b"
exec "/usr/local/bin/weed" mount \
  -filer=127.0.0.1:8988 \
  -dir="/home/ys1000/seaweedfs-hdd/mnt" \
  -volumeName=seaweedfs-b \
  -allowOthers=true \
  -defaultPermissions=true \
  -umask=022 \
  -cacheDir="/home/ys1000/seaweedfs/cache-b" \
  -cacheCapacityMB=128 \
  -cacheMetaTtlSec=60 \
  -chunkSizeLimitMB=2 \
  -writeBufferSizeMB=4096 \
  -concurrentWriters=128 \
  -concurrentReaders=128 \
  -metadataFlushSeconds=120 \
  -fuse.maxBackground=128 \
  -fuse.congestionThreshold=0 \
  -df.logical \
  -dlm
