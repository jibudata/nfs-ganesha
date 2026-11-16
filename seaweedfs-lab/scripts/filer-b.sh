#!/usr/bin/env bash
set -euo pipefail
exec "/usr/local/bin/weed" filer \
  -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -port=8988 -port.grpc=18988 \
  -master=127.0.0.1:9433 \
  -defaultStoreDir="/home/ys1000/seaweedfs/filerldb-b" \
  -collection=""
