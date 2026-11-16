#!/usr/bin/env bash
# SeaweedFS filer (serves the directory tree that `weed mount` exposes over FUSE)
set -euo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

exec "$SW_BIN" filer \
  -ip="$SW_IP" -ip.bind="$SW_IP" \
  -port="$SW_FILER_HTTP" -port.grpc="$SW_FILER_GRPC" \
  -master="$SW_IP:$SW_MASTER_HTTP" \
  -collection=""
