#!/usr/bin/env bash
set -euo pipefail
exec "/usr/local/bin/weed" server \
  -master=false -filer=false \
  -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -volume.port=8281 -volume.port.grpc=18281 \
  -master.peers=127.0.0.1:9533 \
  -master.port=9533 -master.port.grpc=19533 \
  -dir="/home/ys1000/seaweedfs/data-nvme-fresh" \
  -volume.max=8 \
  -volume.readMode=local \
  -dataCenter=dc1
