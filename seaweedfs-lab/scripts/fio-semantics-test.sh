#!/usr/bin/env bash
# Determine fio's job concurrency semantics on this host (within-group vs across-group)
set -uo pipefail
S=/home/ys1000/seaweedfs/scratch
mkdir -p $S

echo "### TEST 1: one group, numjobs=4, distinct filenames ###"
cat > /tmp/fio-t1.fio <<'EOF'
[global]
ioengine=libaio
rw=write
bs=1M
iodepth=16
size=256M
directory=/home/ys1000/seaweedfs/scratch
filename_format=t1.$jobnum

[t1]
numjobs=4
EOF
/usr/local/bin/fio /tmp/fio-t1.fio >/tmp/fio-t1.out 2>&1 &
FIO=$!
sleep 3
echo "  worker threads while running: $(ls /proc/$FIO/task 2>/dev/null | wc -l)"
wait $FIO
grep -E "^t1:|write: IOPS" /tmp/fio-t1.out | head -3
ls -l $S/t1.* 2>/dev/null | awk '{print "   ", $9, $5}'

echo
echo "### TEST 2: four separate groups (stonewall default) ###"
cat > /tmp/fio-t2.fio <<'EOF'
[global]
ioengine=libaio
rw=write
bs=1M
iodepth=16
size=256M
directory=/home/ys1000/seaweedfs/scratch

[g1]
filename=t2.g1
[g2]
filename=t2.g2
[g3]
filename=t2.g3
[g4]
filename=t2.g4
EOF
/usr/local/bin/fio /tmp/fio-t2.fio >/tmp/fio-t2.out 2>&1 &
FIO=$!
sleep 3
echo "  worker threads while running: $(ls /proc/$FIO/task 2>/dev/null | wc -l)"
wait $FIO
grep -E "write: IOPS" /tmp/fio-t2.out | head -3
ls -l $S/t2.* 2>/dev/null | awk '{print "   ", $9, $5}'

rm -f $S/t1.* $S/t2.*
rm -f /tmp/fio-t1.fio /tmp/fio-t2.fio /tmp/fio-t1.out /tmp/fio-t2.out
echo "  (cleaned)"
