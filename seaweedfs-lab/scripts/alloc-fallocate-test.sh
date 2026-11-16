#!/bin/bash
set -uo pipefail
echo "=== FUSE mount health ==="
python3 -c "
import os
for p in ['/home/ys1000/seaweedfs/mnt','/home/ys1000/seaweedfs-hdd/mnt','/home/ys1000/seaweedfs/mnt-nvme-fresh']:
    try:
        os.stat(p); print('  ok ', p)
    except Exception as e:
        print('  BAD', p, e)
"
echo
echo "=== per-operation test, each in its own timed subprocess ==="
for op in fallocate ftruncate plainwrite; do
  timeout 60 python3 - "$op" <<'PY'
import os, sys, time, ctypes, ctypes.util
op = sys.argv[1]
FUSE = "/home/ys1000/seaweedfs/mnt-nvme-fresh"
DATA = "/home/ys1000/seaweedfs/data-nvme-fresh"
SIZE = 256 << 20  # 256 MiB
def datbytes():
    tot = 0
    try:
        for root, dirs, files in os.walk(DATA):
            for f in files:
                if f.endswith(".dat"):
                    try: tot += os.path.getsize(os.path.join(root, f))
                    except OSError: pass
    except OSError: pass
    return tot
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
path = os.path.join(FUSE, "alloc-%s.bin" % op)
d0 = datbytes(); t0 = time.time()
try:
    if op == "fallocate":
        fd = os.open(path, os.O_RDWR|os.O_CREAT|os.O_TRUNC, 0o644)
        rc = libc.fallocate(fd, 0, 0, SIZE)
        os.close(fd)
        if rc != 0: raise OSError(ctypes.get_errno(), "fallocate rc=%d" % rc)
    elif op == "ftruncate":
        fd = os.open(path, os.O_RDWR|os.O_CREAT|os.O_TRUNC, 0o644)
        os.ftruncate(fd, SIZE); os.close(fd)
    else:
        buf = b"\0" * (1<<20)
        fd = os.open(path, os.O_RDWR|os.O_CREAT|os.O_TRUNC, 0o644)
        for _ in range(256): os.write(fd, buf)
        os.close(fd)
    el = time.time()-t0
    d1 = datbytes()
    print("  %-11s elapsed=%6.2fs  .dat_delta=%8.1f MiB  apparent_size=%.1f MiB"
          % (op, el, (d1-d0)/1048576, os.stat(path).st_size/1048576))
except Exception as e:
    print("  %-11s ERROR/HANG: %s" % (op, e))
finally:
    try: os.unlink(path)
    except OSError: pass
PY
  [ $? -ne 0 ] && echo "  $op: TIMED OUT (>60s)"
done
echo "ALLOC2 DONE"
