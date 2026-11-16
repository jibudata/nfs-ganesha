#!/usr/bin/env bash
set -euo pipefail
exec "/usr/local/bin/weed" filer \
  -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -port=9088 -port.grpc=19088 \
  -master=127.0.0.1:9533 \
  -defaultStoreDir="/home/ys1000/seaweedfs/filerldb-nvme-fresh" \
  -collection=""
