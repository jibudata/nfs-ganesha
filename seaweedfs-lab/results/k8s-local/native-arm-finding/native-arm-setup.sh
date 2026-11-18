#!/bin/bash
# =====================================================================
# native-arm-setup.sh - run the SAME Ganesha+FUSE+SeaweedFS stack as
# plain processes inside the colima VM (no docker, no K8s), for
# comparing against the K8s pod arm on the identical VM/disk/client.
#
#   usage: sudo bash native-arm-setup.sh start|stop|status
#
# Ports: master 19350/29350, volume 19352/29352, filer 19354/29354,
# NFS 20490.  Data on the big disk: /mnt/lima-colima/native-arm/.
# =====================================================================
set -uo pipefail

ROOT=/mnt/lima-colima/native-arm
SW=/usr/local/bin/weed
Ganesha=/usr/local/bin/ganesha.nfsd
CONF=$ROOT/ganesha.conf
LOGS=$ROOT/logs
mkdir -p $ROOT/{master,vol,ldb,cache,mnt,logs}

cat > $CONF <<'EOF'
NFS_CORE_PARAM {
    NFS_Port = 20490;
    Protocols = 4;
    Enable_UDP = false;
    Enable_TCP_keepalive = true;
    Enable_Metrics = false;
    Enable_Dynamic_Metrics = false;
}
NFSv4 {
    Lease_Lifetime = 10;
    Grace_Period = 10;
    minor_versions = 0,1;
    Delegations = false;
}
EXPORT {
    Export_Id = 1;
    Path = "/mnt/lima-colima/native-arm/mnt";
    Pseudo = "/seaweedfs";
    Access_Type = RW;
    Squash = Root_Squash;
    Protocols = 4;
    Transports = TCP;
    SecType = sys;
    MaxWrite = 1048576;
    MaxRead = 1048576;
    FSAL { Name = VFS; }
}
EXPORT_DEFAULTS { Access_Type = RW; Squash = Root_Squash; }
LOG { Facility { name = FILE; destination = "/mnt/lima-colima/native-arm/logs/ganesha.log"; enable = active; } }
EOF

start_one() { # <name> <cmd...>
  local name=$1; shift
  if [ -f "$ROOT/$name.pid" ] && kill -0 "$(cat $ROOT/$name.pid)" 2>/dev/null; then
    echo "$name already running"; return 0
  fi
  nohup "$@" >> "$LOGS/$name.log" 2>&1 &
  echo $! > "$ROOT/$name.pid"
  sleep 1
  kill -0 "$(cat $ROOT/$name.pid)" 2>/dev/null && echo "$name started (pid $(cat $ROOT/$name.pid))" \
    || { echo "ERROR: $name died; see $LOGS/$name.log"; return 1; }
}

do_start() {
  mkdir -p /var/run/ganesha /var/lib/nfs/ganesha
  start_one master $SW master -ip=127.0.0.1 -ip.bind=127.0.0.1 \
    -port=19350 -port.grpc=29350 -mdir=$ROOT/master -peers=none \
    -vacuumIntervalSeconds=86400 -telemetry=false -volumeSizeLimitMB=30720 || return 1
  sleep 2
  # The fork's master freezes volume growth after any state loss (fresh
  # raft while filer/mount metadata is still alive).  Resume it so
  # AssignVolume does not hang and uploads fail silently.
  printf "lock\nvolume.growth.resume\nunlock\nexit\n" \
    | "$SW" shell -master=127.0.0.1:19350 >/dev/null 2>&1 || true
  start_one volume $SW server -master=false -filer=false \
    -ip=127.0.0.1 -ip.bind=127.0.0.1 \
    -volume.port=19352 -volume.port.grpc=29352 \
    -master.peers=127.0.0.1:19350 \
    -master.port=19350 -master.port.grpc=29350 \
    -dir=$ROOT/vol -volume.max=8 -volume.readMode=local -dataCenter=dc1 || return 1
  sleep 2
  start_one filer $SW filer -ip=127.0.0.1 -ip.bind=127.0.0.1 \
    -port=19354 -port.grpc=29354 -master=127.0.0.1:19350 \
    -defaultStoreDir=$ROOT/ldb || return 1
  sleep 2
  if ! grep -qs " $ROOT/mnt " /proc/mounts; then
    start_one weedmount $SW mount -filer=127.0.0.1:19354 \
      -dir=$ROOT/mnt -volumeName=native-arm -allowOthers=true \
      -defaultPermissions=true -umask=022 -cacheDir=$ROOT/cache \
      -cacheCapacityMB=128 -cacheMetaTtlSec=60 -chunkSizeLimitMB=2 \
      -writeBufferSizeMB=4096 -concurrentWriters=16 -concurrentReaders=16 \
      -metadataFlushSeconds=120 -fuse.maxBackground=128 \
      -fuse.congestionThreshold=0 -df.logical -dlm || return 1
  else
    echo "weedmount already mounted"
  fi
  sleep 2
  if grep -qs "fuse.seaweedfs" /proc/mounts && grep -qs "$ROOT/mnt" /proc/mounts; then
    echo "FUSE mount OK"
  else
    echo "ERROR: FUSE mount missing"; return 1
  fi
  start_one ganesha $Ganesha -F -f $CONF -N NIV_EVENT \
    -L /mnt/lima-colima/native-arm/logs/ganesha-stdout.log || return 1
  sleep 3
  kill -0 "$(cat $ROOT/ganesha.pid)" 2>/dev/null && echo "ganesha OK (pid $(cat $ROOT/ganesha.pid))" \
    || { echo "ERROR: ganesha died; see $LOGS/ganesha-stdout.log"; return 1; }
  mkdir -p $ROOT/mnt/fio && chmod 0777 $ROOT/mnt/fio
  echo "=== native arm up: NFS on 0.0.0.0:20490, export /seaweedfs ==="
}

do_stop() {
  for n in ganesha weedmount filer volume master; do
    if [ -f "$ROOT/$n.pid" ]; then
      kill "$(cat $ROOT/$n.pid)" 2>/dev/null || true
      rm -f "$ROOT/$n.pid"
    fi
  done
  pkill -x ganesha.nfsd 2>/dev/null
  # bounded lazy unmount (LAB-CONVENTIONS R3)
  grep -qs " $ROOT/mnt " /proc/mounts && { umount -l $ROOT/mnt 2>/dev/null || true; }
  echo "native arm stopped"
}

do_status() {
  for n in master volume filer weedmount ganesha; do
    if [ -f "$ROOT/$n.pid" ] && kill -0 "$(cat $ROOT/$n.pid)" 2>/dev/null; then
      echo "$n: running"
    else
      echo "$n: DOWN"
    fi
  done
  grep -qs "fuse.seaweedfs" /proc/mounts && echo "fuse: mounted" || echo "fuse: NOT mounted"
}

case "${1:-status}" in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
