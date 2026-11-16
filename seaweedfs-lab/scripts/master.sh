#!/usr/bin/env bash
# SeaweedFS master (metadata + volume topology)
set -euo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

exec "$SW_BIN" master \
  -ip="$SW_IP" -ip.bind="$SW_IP" \
  -port="$SW_MASTER_HTTP" -port.grpc="$SW_MASTER_GRPC" \
  -mdir="$SW_MASTER_DIR" \
  -peers=none \
  -telemetry=false \
  -volumeSizeLimitMB=30720
