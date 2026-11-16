#!/usr/bin/env bash
# SeaweedFS FUSE mount -- the "FUSE" layer that NFS-Ganesha will export.
#
# This is the file access gateway for the whole test bed:
#   NFS client -> Ganesha (FSAL_VFS) -> this FUSE mount -> filer -> volume
set -euo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

mkdir -p "$SW_MNT" "$SW_CACHE_DIR"

exec "$SW_BIN" mount \
  -filer="$SW_IP:$SW_FILER_HTTP" \
  -dir="$SW_MNT" \
  -volumeName=seaweedfs \
  -allowOthers=true \
  -defaultPermissions=true \
  -umask=022 \
  -cacheDir="$SW_CACHE_DIR" \
  -cacheCapacityMB="$SW_CACHE_CAPACITY_MB" \
  -cacheMetaTtlSec="$SW_CACHE_META_TTL" \
  -chunkSizeLimitMB="$SW_CHUNK_SIZE_MB" \
  -writeBufferSizeMB="$SW_WRITE_BUFFER_MB" \
  -concurrentWriters="$SW_CONC_WRITERS" \
  -concurrentReaders="$SW_CONC_READERS" \
  -metadataFlushSeconds="$SW_META_FLUSH_SEC" \
  -fuse.maxBackground="$SW_MAX_BACKGROUND" \
  -fuse.congestionThreshold="$SW_CONGESTION_THRESHOLD" \
  -df.logical \
  -dlm
