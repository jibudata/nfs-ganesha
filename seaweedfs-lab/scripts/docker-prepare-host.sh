#!/bin/bash
# =====================================================================
# docker-prepare-host.sh
#
# Host-side preparation for the containerised arm of the comparison:
# create the data directories on the same NVMe device the bare-metal
# clusters use, build the image, start the storage plane and mount the
# host-side FUSE gateway on top of it.
#
#   usage: bash docker-prepare-host.sh [up|down|status]
#
# The FUSE gateway runs on the HOST (scripts/docker-fuse-mount.sh) and
# talks to the container's filer through the published port.  The FUSE
# mount was tried inside the container first: it does not propagate back to
# the host, because the container's mount lands in a different peer group
# (shared:1944 inside, shared:1 on the host) and the propagation stops
# there.  Ganesha then silently dropped the export and the 32 MiB probe
# landed in the host's own ext4 directory instead of in SeaweedFS.
#
# r10-exempt: this script CREATES a brand-new backend.  There is no
# Ganesha export for it yet, so no dirfd can be invalidated.  The export
# is added afterwards, and Ganesha is restarted then.
# =====================================================================
set -uo pipefail

. "$(dirname "$0")/lib-nfslab.sh"

LAB_ROOT=${LAB_ROOT:-/home/ys1000/seaweedfs}
COMPOSE_DIR=${COMPOSE_DIR:-$LAB_ROOT/docker}
IMAGE=${IMAGE:-seaweedfs-lab:4.54}
FILER_PORT=${DOCKER_FILER_PORT:-19344}
ACTION=${1:-up}

MNT="$LAB_ROOT/mnt-docker"
DIRS=("$LAB_ROOT/docker-master" "$LAB_ROOT/docker-data" "$LAB_ROOT/docker-ldb" \
      "$LAB_ROOT/docker-cache" "$LAB_ROOT/docker-log" "$LAB_ROOT/docker-fuse-cache")

case "$ACTION" in
down)
  echo "=== stopping the containerised arm ==="
  bash "$(dirname "$0")/docker-fuse-mount.sh" down
  cd "$COMPOSE_DIR" && docker compose down 2>&1 | tail -3
  echo "done"
  exit 0
  ;;

status)
  echo "=== containerised arm ==="
  docker ps --filter name=seaweedfs-lab --format '  container: {{.Names}} {{.Status}}'
  bash "$(dirname "$0")/docker-fuse-mount.sh" status
  for d in "${DIRS[@]}"; do
    printf "  %-44s %s\n" "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  exit 0
  ;;
esac

echo "=== prepare the containerised arm ==="

# ---- directories on the same NVMe device as the bare-metal clusters ----
for d in "${DIRS[@]}" "$MNT"; do
  mkdir -p "$d"
done
echo "  data directories ready"

# ---- the image, built from the host's own binary -----------------------
bash "$COMPOSE_DIR/build-image.sh" "$IMAGE" || exit 1

# ---- start the storage plane ------------------------------------------
echo "--- starting the stack"
cd "$COMPOSE_DIR" && docker compose up -d 2>&1 | tail -4

echo "--- waiting for the filer on 127.0.0.1:$FILER_PORT"
# A TCP accept is NOT enough: Docker's port proxy accepts the connection
# and then resets it when the service inside is bound to the container's
# own loopback instead of the container's address.  Ask for the status
# page and require an answer.
for i in $(seq 1 60); do
  code=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FILER_PORT/" 2>/dev/null || true)
  if [ "$code" = "200" ]; then
    echo "  ok     the filer answers on 127.0.0.1:$FILER_PORT after ${i}s"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: the filer never answered on $FILER_PORT (last http code: ${code:-none})" >&2
    docker logs --tail 40 seaweedfs-lab >&2
    exit 1
  fi
  sleep 1
done

# ---- the host-side FUSE gateway ----------------------------------------
# A leftover bind mount of the mount point (the shared-mount trick the
# first version used) would sit under the FUSE mount and confuse every
# later check, so take it away first.
if is_mounted "$MNT" && ! is_fuse_mounted "$MNT"; then
  echo "--- removing the stale bind mount on $MNT"
  lazy_unmount "$MNT"
fi

echo "--- mounting the FUSE gateway on the host"
bash "$(dirname "$0")/docker-fuse-mount.sh" up || exit 1

# ---- prove the stack actually serves -----------------------------------
echo "--- verify the mount is really writable through the host path"
probe="$MNT/.docker-probe.$$"
if printf 'containerised arm probe\n' > "$probe" 2>/dev/null; then
  bytes=$(wc -c < "$probe")
  echo "  ok     wrote $bytes bytes through $MNT"
else
  echo "ERROR: cannot write through $MNT" >&2
  exit 1
fi

echo "prepare done"
echo
echo "Next: add an export for $MNT to /etc/ganesha/ganesha.conf and restart Ganesha."
echo "      scripts/ganesha-add-export.sh does that."
