#!/usr/bin/env bash
# SeaweedFS master (metadata + volume topology)
set -euo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env

# The automatic vacuum sweep rewrites whole volumes and interrupts the
# in-flight chunk upload ("multipart: NextPart: unexpected EOF", HTTP 400),
# which wedges the FUSE mount, then the Ganesha export, then the NFS client.
# 86400 s keeps the sweep out of the measurement window.  See LAB-CONVENTIONS
# R11: every master startup script must carry this, with the same value.
exec "$SW_BIN" master \
  -ip="$SW_IP" -ip.bind="$SW_IP" \
  -port="$SW_MASTER_HTTP" -port.grpc="$SW_MASTER_GRPC" \
  -mdir="$SW_MASTER_DIR" \
  -peers=none \
  -vacuumIntervalSeconds=86400 \
  -telemetry=false \
  -volumeSizeLimitMB=30720
