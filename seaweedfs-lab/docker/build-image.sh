#!/bin/bash
# =====================================================================
# build-image.sh
#
# Build the SeaweedFS image used by the containerised arm of the comparison.
# The image COPIES the lab host's own binary, so the containerised backend is
# the exact same build as the bare-metal one (4.54, commit 5ef99c1d).
#
#   usage: bash build-image.sh [image:tag] [--fio]
#
# Two variants:
#
#   (plain)  the storage plane: SeaweedFS only, debian:bookworm-slim.
#            Used by the Docker arm and by the Kubernetes storage plane.
#   --fio    the pod that mounts FUSE and writes with fio: SeaweedFS plus
#            fio, on the host's own distro (ubuntu:24.04) so the version is
#            the host's.  The image's fio is the Ubuntu package (3.36), not
#            the host's local build: the local build links against ~70
#            shared libraries to enable the gluster/ceph/rbd/nbd backends,
#            and this benchmark uses none of them.  The VERSION is what
#            has to match, and it is checked below.
#
# Run it on the lab host.  The build context is a scratch directory under
# the lab root; nothing is deleted at the end (the desktop's delete guard
# turns "rm" in a script into an interactive trash call that would hang).
# =====================================================================
set -euo pipefail

VARIANT=plain
IMAGE=""
case "${2:-}" in
  "")    IMAGE=${1:-seaweedfs-lab:4.54} ;;
  --fio) VARIANT=fio; IMAGE=${1:-seaweedfs-lab:4.54-fio} ;;
  *) echo "usage: $0 [image:tag] [--fio]" >&2; exit 2 ;;
esac

LAB_ROOT=${LAB_ROOT:-/home/ys1000/seaweedfs}
HOST_BIN=${HOST_BIN:-/usr/local/bin/weed}
HOST_FIO=${HOST_FIO:-/home/ys1000/seaweedfs/tools/fio}
HOST_FIO_LIB=${HOST_FIO_LIB:-/home/ys1000/seaweedfs/tools/lib}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "=== build $IMAGE (variant: $VARIANT) ==="

if [ ! -x "$HOST_BIN" ]; then
  echo "ERROR: $HOST_BIN is not there; this script has to run on the lab host" >&2
  exit 2
fi

# The version string, and nothing else.  fio prints it on stdout and a
# copyright banner on stderr; in a pipe the banner can land first, so
# grep for the token instead of taking the first line - the same trap
# "weed version" has, and the reason build_id() below exists.
fio_version() {
  local raw
  raw=$(LD_LIBRARY_PATH="$HOST_FIO_LIB" "$1" --version 2>&1 || true)
  printf '%s\n' "$raw" | grep -oE 'fio-[0-9]+(\.[0-9]+)*' | sed -n '1p' || true
}

if [ "$VARIANT" = "fio" ]; then
  CONTEXT="$LAB_ROOT/docker-build-fio"
  mkdir -p "$CONTEXT"
  cp "$HOST_BIN" "$CONTEXT/weed"
  cp "$HERE/Dockerfile-fio" "$CONTEXT/Dockerfile"
  cp "$HERE/../k8s/run-fuse-fio.sh" "$CONTEXT/run-fuse-fio.sh"
  echo "  fio:     $(fio_version "$HOST_FIO")  (host)"
else
  CONTEXT="$LAB_ROOT/docker-build"
  mkdir -p "$CONTEXT"
  cp "$HOST_BIN" "$CONTEXT/weed"
  cp "$HERE/Dockerfile" "$CONTEXT/Dockerfile"
  cp "$HERE/entrypoint.sh" "$CONTEXT/entrypoint.sh"
fi

# The Dockerfile and the binary must be the same build: check the version
# string of the binary that is about to be baked into the image.
#
# Two traps, both hit on the first run:
#
#  1. Piping into "head -1" closes the pipe early, the writer dies of
#     SIGPIPE, "pipefail" turns that into a non-zero status and "set -e"
#     kills the script right there.
#  2. "weed version" writes the version line to STDOUT and the banner to
#     STDERR.  On a terminal they interleave the way you expect; in a pipe
#     the unbuffered stderr lands first, so "the first line" is the banner
#     - and on the host it is the version line.  Comparing the first line
#     across the two therefore compares different things.
#
# So compare the BUILD ID, which is in the output wherever it lands, and
# never rely on line order.
build_id() {
  printf '%s\n' "$1" | grep -oE '[0-9a-f]{40}' | sed -n '1p'
}

host_version_raw=$("$HOST_BIN" version 2>&1 || true)
host_id=$(build_id "$host_version_raw")
echo "  host binary: $(printf '%s\n' "$host_version_raw" | grep -oE 'version [0-9]+GB [0-9.]+ [0-9a-f]{40}' | sed -n '1p')"

docker build -t "$IMAGE" "$CONTEXT"

echo "--- verify the image carries the same build"
image_version_raw=$(docker run --rm --entrypoint /usr/local/bin/weed "$IMAGE" version 2>&1 || true)
image_id=$(build_id "$image_version_raw")
echo "  image binary: $(printf '%s\n' "$image_version_raw" | grep -oE 'version [0-9]+GB [0-9.]+ [0-9a-f]{40}' | sed -n '1p')"

if [ -z "$host_id" ] || [ "$host_id" != "$image_id" ]; then
  echo "ERROR: the image's binary differs from the host's" >&2
  echo "  host:  $host_id" >&2
  echo "  image: $image_id" >&2
  exit 1
fi
echo "  ok     same build in the host and in the image ($host_id)"

# For the fio variant the version of fio matters just as much: the
# benchmark compares numbers with the other arms, and a different fio
# would make the comparison meaningless.  The image's fio is the Ubuntu
# package and the host's is a local build, but both must report the same
# fio-X.Y.
if [ "$VARIANT" = "fio" ]; then
  host_fio=$(fio_version "$HOST_FIO")
  image_fio=$(docker run --rm --entrypoint /usr/bin/fio "$IMAGE" --version 2>&1 \
              | grep -oE 'fio-[0-9]+(\.[0-9]+)*' | sed -n '1p' || true)
  echo "  fio:     host=$host_fio image=$image_fio"
  if [ -z "$host_fio" ] || [ "$host_fio" != "$image_fio" ]; then
    echo "ERROR: the image's fio differs from the host's" >&2
    echo "  host:  $host_fio" >&2
    echo "  image: $image_fio" >&2
    exit 1
  fi
  echo "  ok     same fio in the host and in the image ($host_fio)"
fi

docker images "$IMAGE" --format '  image: {{.Repository}}:{{.Tag}} {{.Size}}'
echo "build done"
