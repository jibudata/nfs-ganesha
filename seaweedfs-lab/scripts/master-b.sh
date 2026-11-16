#!/usr/bin/env bash
set -euo pipefail
exec "/usr/local/bin/weed" master \
  -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -port=9433 -port.grpc=19433 \
  -mdir="/home/ys1000/seaweedfs/master-b" \
  -peers=none \
  -vacuumIntervalSeconds=86400 \
  -telemetry=false \
  -volumeSizeLimitMB=30720
