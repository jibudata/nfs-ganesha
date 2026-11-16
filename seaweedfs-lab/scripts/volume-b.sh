#!/usr/bin/env bash
set -euo pipefail
exec "/usr/local/bin/weed" server \
  -master=false -filer=false \
  -ip=127.0.0.1 -ip.bind=127.0.0.1 \
  -volume.port=8181 -volume.port.grpc=18181 \
  -master.peers=127.0.0.1:9433 \
  -master.port=9433 -master.port.grpc=19433 \
  -dir="/home/ys1000/seaweedfs-hdd/data" \
  -volume.max=8 \
  -volume.readMode=local \
  -dataCenter=dc1
