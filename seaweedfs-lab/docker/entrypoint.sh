#!/bin/bash
# =====================================================================
# entrypoint.sh - runs INSIDE the container.
#
# The container runs the STORAGE PLANE only: master, volume server and
# filer.  The FUSE mount stays on the host, as a plain systemd service, and
# talks to the filer over the published port.
#
# That split is the point of the experiment.  Ganesha and the FUSE gateway
# are the same in every arm of the comparison, so the only variable is the
# storage backend: on the host, in a container, in Kubernetes.  Putting the
# FUSE mount inside the container would have added a mount-propagation
# dependency - the container's mount lands in a different peer group than
# the host's, so the FUSE mount does NOT propagate back - and changed two
# things at once: the packaging AND the position of the gateway.
#
# One container, three processes, all on the container's loopback - the same
# shape as the bare-metal host, where master, volume, filer and mount all
# run on one machine.
#
# Every flag is copied from the bare-metal start scripts (scripts/master.sh,
# scripts/volume.sh, scripts/filer.sh).  If a flag is changed here, it has
# to be changed there too.
# =====================================================================
set -uo pipefail

SW_BIN=/usr/local/bin/weed
LOGDIR=/work/log
mkdir -p "$LOGDIR"

log() { echo "[$(date +%T)] $*"; }

# The services have to bind the CONTAINER's address, not 127.0.0.1.  On the
# bare-metal host 127.0.0.1 is the host's loopback and everything is local;
# inside a container it is the container's own loopback, and Docker's port
# proxy connects to the container's IP - so a service bound to 127.0.0.1
# accepts the published TCP connection and then resets it.  The symptom is
# "connection reset by peer" on a port that is plainly LISTENing.
IP=$(hostname -i | awk '{print $1}')
log "container address: $IP"

# wait for a TCP port to accept connections, without needing curl
wait_port() {
  local host=$1 port=$2 tries=${3:-60} i
  for ((i = 0; i < tries; i++)); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 1
  done
  return 1
}

# ---- master ------------------------------------------------------------
log "starting master"
"$SW_BIN" master \
  -ip="$IP" -ip.bind="$IP" \
  -port=9333 -port.grpc=19333 \
  -mdir=/data/master \
  -peers=none \
  -vacuumIntervalSeconds=86400 \
  -telemetry=false \
  -volumeSizeLimitMB=30720 > "$LOGDIR/master.log" 2>&1 &
MASTER_PID=$!
if ! wait_port "$IP" 9333 60; then
  log "FATAL: the master did not come up"; tail -20 "$LOGDIR/master.log"; exit 1
fi

# The automatic vacuum sweep is a runtime flag and does not survive a
# restart; -vacuumIntervalSeconds only spaces the sweeps out, and the sweep
# loop runs its body BEFORE the first sleep, so a fresh master sweeps once
# immediately.  Turn it off explicitly.  See LAB-CONVENTIONS.md R11.
if printf 'lock\nvolume.vacuum.disable\nunlock\nexit\n' \
     | "$SW_BIN" shell -master="$IP:9333" > "$LOGDIR/vacuum-disable.log" 2>&1; then
  log "automatic vacuum sweep disabled"
else
  log "WARNING: could not disable the automatic vacuum sweep"
fi

# ---- volume server -----------------------------------------------------
log "starting volume server"
"$SW_BIN" server \
  -master=false -filer=false \
  -ip="$IP" -ip.bind="$IP" \
  -volume.port=8081 -volume.port.grpc=18081 \
  -master.peers="$IP:9333" \
  -master.port=9333 -master.port.grpc=19333 \
  -dir=/data/vol \
  -volume.max=8 \
  -volume.readMode=local \
  -dataCenter=dc1 > "$LOGDIR/volume.log" 2>&1 &
VOLUME_PID=$!
wait_port "$IP" 8081 60 || { log "FATAL: the volume server did not come up"; tail -20 "$LOGDIR/volume.log"; exit 1; }

# ---- filer -------------------------------------------------------------
log "starting filer"
# -defaultStoreDir points the filer's own LevelDB - the directory tree -
# at the mounted volume.  Without it the default is "." (the process's
# working directory), so the tree lands in the container's writable
# layer: not on the NVMe device, and gone when the container is
# recreated.  The bare-metal arm keeps the same store in
# /home/ys1000/seaweedfs/filerldb2, which is on the NVMe and persistent,
# so leaving it at the default would make this arm measure something
# the other arms do not.  See weed/command/filer.go:145 and :400.
"$SW_BIN" filer \
  -ip="$IP" -ip.bind="$IP" \
  -port=8888 -port.grpc=18888 \
  -master="$IP:9333" \
  -defaultStoreDir=/data/ldb \
  -collection="" > "$LOGDIR/filer.log" 2>&1 &
FILER_PID=$!
wait_port "$IP" 8888 60 || { log "FATAL: the filer did not come up"; tail -20 "$LOGDIR/filer.log"; exit 1; }

# ---- stay alive while the storage plane is up --------------------------
# The container's job is to serve the storage plane.  It stops when ANY
# of the three services dies - a container that answers "am I running?"
# while serving nothing is worse than one that is down.
#
# THE FILER HAS TO BE WATCHED TOO.  It was not, and that is how a dead
# filer went unnoticed for hours on 2026-11-16: the master and the
# volume server were still up, so the container stayed "Up", the host's
# FUSE mount kept retrying a connection that would never come back, and
# every write through that export blocked forever.  The host's load
# average went to 98 and `ps` stopped working on it.
trap 'log "stopping"; kill "$FILER_PID" "$VOLUME_PID" "$MASTER_PID" 2>/dev/null; wait' TERM INT

while true; do
  for svc in "master:$MASTER_PID" "volume:$VOLUME_PID" "filer:$FILER_PID"; do
    svc_name=${svc%%:*}
    svc_pid=${svc##*:}
    if ! kill -0 "$svc_pid" 2>/dev/null; then
      log "the $svc_name exited; the storage plane is no longer complete"
      tail -20 "$LOGDIR/$svc_name.log" 2>/dev/null
      kill "$FILER_PID" "$VOLUME_PID" "$MASTER_PID" 2>/dev/null
      wait
      exit 1
    fi
  done
  sleep 2
done
