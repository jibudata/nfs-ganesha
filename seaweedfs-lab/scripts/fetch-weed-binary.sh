#!/usr/bin/env bash
# Stage the `weed` binary from a pinned SeaweedFS container image.
#
# The Ganesha+FUSE pod image serves the export through a FUSE mount made by
# `weed mount`, and that mount has to come from the same SeaweedFS revision
# the storage plane (or the standalone FUSE arm) runs, or the comparison is
# not apples to apples.  Rather than downloading a release tarball whose
# naming and layout move between releases, extract the binary out of the
# pinned image itself.
#
#   usage: bash fetch-weed-binary.sh <dest-path> [image]
#
# Writes <dest-path>; the Ganesha image build COPYs it from the build context.
set -euo pipefail

DEST=${1:?usage: fetch-weed-binary.sh <dest-path> [image]}
IMAGE=${2:-chrislusf/seaweedfs:4.54}

cid=$(docker create "$IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

mkdir -p "$(dirname "$DEST")"
copied=0
for binary in /usr/bin/weed /usr/local/bin/weed; do
  if docker cp "$cid:$binary" "$DEST" 2>/dev/null; then
    copied=1
    break
  fi
done
if [ "$copied" -ne 1 ]; then
  echo "ERROR: could not find weed in $IMAGE" >&2
  exit 1
fi
chmod 0755 "$DEST"
printf 'staged %s weed -> %s\n' "$IMAGE" "$DEST"
