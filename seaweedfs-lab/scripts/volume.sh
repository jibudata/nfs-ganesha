#!/usr/bin/env bash
# SeaweedFS volume server (stores the actual chunks)
set -euo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

exec "$SW_BIN" server \
  -master=false -filer=false \
  -ip="$SW_IP" -ip.bind="$SW_IP" \
  -volume.port="$SW_VOLUME_HTTP" -volume.port.grpc="$SW_VOLUME_GRPC" \
  -master.peers="$SW_IP:$SW_MASTER_HTTP" \
  -master.port="$SW_MASTER_HTTP" -master.port.grpc="$SW_MASTER_GRPC" \
  -dir="$SW_DATA_DIR" \
  -volume.max=8 \
  -volume.readMode=local \
  -dataCenter=dc1
