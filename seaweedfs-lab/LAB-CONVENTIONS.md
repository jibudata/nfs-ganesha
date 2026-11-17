# Lab script conventions

Rules for every script under `seaweedfs-lab/scripts/` (and its remote twin in
`/home/ys1000/seaweedfs/scripts/`).

Each rule below corresponds to a footgun that actually cost time on 2026-11-16.
Mechanical rules are checked by `scripts/lint-lab-script.sh`; run it before you
call a script done:

```bash
bash seaweedfs-lab/scripts/lint-lab-script.sh seaweedfs-lab/scripts/my-new-script.sh
```

**The whole tree must pass.** `bash lint-lab-script.sh seaweedfs-lab/scripts/*.sh`
has to come back `PASS` with no ERROR and no WARN. A guardrail that the
lab's own scripts do not follow is decoration — the tree was found failing its
own linter (21 ERRORs) on 2026-11-16, and fixing the scripts was the only
honest fix; loosening the rules to make the tree green would have hidden the
problem.

## 0. Use the shared helpers

`scripts/lib-nfslab.sh` already implements the tricky parts. Source it and do
not hand-roll them again:

```bash
. "$(dirname "$0")/lib-nfslab.sh"

is_mounted   <path>      # R2: read /proc/mounts, never stat the path
lazy_unmount <path>      # R3: lazy unmount in the background, then wait
bounded_unmount <path> [secs]   # R3 for a systemd ExecStop: bounded by timeout
pids_of      <string>    # R1: pids whose cmdline contains a literal string
pids_of_re   <ere>       # R1: same, with an extended regular expression
```

---

## 1. Process handling

**R1 — Never `pgrep -f` / `pkill -f`.** The pattern matches the shell that is running
the command, so the script kills its own session (symptom: the ssh call returns no
output and hangs).

Use one of:

```bash
pkill -x fio                       # exact process name
pids_of "weed mount"               # shared helper: scans /proc/<pid>/cmdline
```

When the scan is hand-rolled, excluding only `$$` and `$PPID` is **not enough**:
the shell that carries the ssh command line is the grandparent of the script and
its command line contains the pattern too. The shared helper therefore skips the
whole ancestor chain, and the processes the caller itself forked (a command
substitution or a pipeline component inherits the caller's command line, so it
matches the pattern as well).

## 2. Mount points

**R2 — Never `stat` a mount point to ask whether it is mounted.** `mountpoint -q`,
`stat`, `ls` on a wedged NFS client block in uninterruptible sleep and hang the
script. Read the kernel table instead:

```bash
is_mounted() { awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' /proc/mounts; }
```

Same for `df` / `du` on an NFS mount — use `stat -f -c "%b %a %S"`.

**R3 — Never `umount` synchronously, and always bound it.** On a wedged NFS
client `umount(2)` blocks in D state and cannot be killed, not even by SIGKILL.
An unmount must be **bounded** — one of these two:

```bash
( sudo umount -l "$path" >/dev/null 2>&1 ) &   # lazy, in the background
timeout 15 sudo umount -l "$path"              # bounded by a timeout
```

The background form is the default. The timeout form is the one to use in a
**systemd `ExecStop`**: `KillMode=control-group` (the default) kills the
remaining processes of the unit the moment `ExecStop` exits, so a backgrounded
unmount would be killed before it finished — and a FUSE mount that stays
registered is exactly the dead-mount condition R2 exists to detect.

Mount on a **new** path for every case; only ever add.

## 3. Reporting a result

**R4 — A case is void until the bytes are proven to have landed.** The volume
server's `.dat` files are the only trustworthy witness:

```bash
landed=$(( (d1 - d0)/1048576 ))
[ "$landed" -lt $((wrote/2)) ] && echo "*** DATA DID NOT LAND ***"
```

This is not paranoia: on 2026-11-16 a wedged FUSE mount accepted every NFS write,
returned success, kept the file size correct — and dropped the data. The
block-size conclusion built on that run was fiction.

**R4a — The landing probe must write NON-ZERO data.** SeaweedFS stores all-zero
chunks as references: `dd if=/dev/zero` of 4 GiB moved only 4 MiB to the volume
server. A probe or benchmark that writes zeros therefore **false-negatives** —
the `.dat` does not grow even though the data was accepted and stored. fio's
default `scramble_buffers=1` writes non-zero data, so fio cases are fine; a
hand-rolled `dd`/`cat` probe is not. Use `/dev/urandom`, and treat "the bytes
did not move" as "the bytes were zero" before concluding "the bytes were lost".


**R5 — A `strace` run has produced nothing until its output file is non-empty.**
`strace -e trace=pwritev,fsync,fdatasync2` fails outright when the kernel lacks one
of the named syscalls, writes no file, and (with stderr swallowed) is invisible.

```bash
[ -s "$trace" ] || { echo "strace produced no output"; exit 1; }
```

**R6 — Fetch Prometheus to a file, then parse it.** `curl ... | wc -l` miscounts
metric lines and loses labels.

**R7 — Take the bandwidth from fio's GROUP aggregate.** With `numjobs>1` the
per-job lines each carry one job's `BW=`; the group line carries the aggregate.
Taking the first `bw=` match silently reports one job's throughput. Two correct
forms:

```bash
grep -E '^[[:space:]]*WRITE:[[:space:]]*bw=' "$out"     # the group summary line
grep -oE 'bw=[0-9.]+[KMG]iB/s' "$out" | tail -1          # the last match
```

The group summary is uppercase (`WRITE: bw=`), the per-job lines are lowercase
(`write: IOPS=..., BW=...`), so the first form is unambiguous. `head -1` on the
second form is the bug.

**R8 — Check fio's exit code.** A non-zero rc with a plausible-looking throughput
happened (fio printed `Bad option` and exited).

**R27 — A unit parsed out of fio's output comes out of the parentheses, and every
latency column in a CSV carries the same unit.** fio picks the unit from the
magnitude and prints it in the section header: `clat (usec):`. Stripping the header
with `tr -d 'clat ():'` is wrong — `tr` deletes *every character in the set*, so
`clat (usec):` comes out as `use` and `clat (msec):` as `mse`. The three-arm
comparison shipped a CSV whose `clat_unit` column said `nse`, `mse` and `use`: three
different runs of the same case had their latencies in three different units, none
of them recoverable from the file, and a reader could not tell msec from usec.

Take the unit out of the parentheses and convert, so the number in the CSV is always
the same unit:

```bash
# lib-nfslab.sh provides this; the pod-side copy lives in k8s/run-fuse-fio.sh
clat_ms=$(fio_clat_ms "$fio_out")
```

The rule is not only about the unit string. A CSV column of latencies with no unit
next to it is a unit waiting to be misread: `3386551.40` is 3.4 seconds in one run
and 3.4 milliseconds in another. Normalise at the point of parsing and name the
column accordingly (`clat_avg_ms`).

**R29 — A median is the middle of the SORTED values.** The rows arrive in round
order, not in bandwidth order, so "take the middle element" is not the median. The
fourth-form renderer did exactly that and reported three rounds of 1000, 692 and
1008 MiB/s as **692** — which made the FUSE-in-a-pod arm look *36% slower* than
the NFS path, the opposite of the truth. The noise was being read as a result.

Sort before you take the middle, and make the sort part of the same awk program so
it cannot be forgotten:

```awk
function median(a, n,   i, j, t) {
  for (i = 2; i <= n; i++) {                 # insertion sort
    t = a[i]
    for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
    a[j + 1] = t
  }
  if (n % 2) return a[(n + 1) / 2]
  return (a[n / 2] + a[n / 2 + 1]) / 2
}
```

Two related traps in the same renderer, both worth stating because the file's own
header promised otherwise:
- **a void case is counted but never folded into a median.** The rows are sorted by
  bandwidth, so a void row with a high number lands right next to the median and
  drags it up.
- **a per-group counter has to be reset when the group changes.** A `voids` counter
  that is added to but never reset accumulates across every group in the file.

**And one that is easy to miss because the table looks right: every column is its
OWN median.** Taking the element at the median index of the bandwidth-sorted array
couples the latency and the CPU columns to "the round that happened to have the
median bandwidth" — a different number from the median latency, and one that reads
as the same thing when the column is called a median. For the bare arm on buf1M the
two differ by 8%: the median-bandwidth round had a 14.664 ms write latency, the
median latency is 13.516 ms. Sort and take the median per column.

## 4. CPU accounting

**R9 — Bound the arithmetic.** CPU seconds consumed cannot exceed
`elapsed × ncores`. If a computed value breaks that bound, the counter arithmetic
is broken — this catches the bug instantly instead of after two debugging rounds:

```bash
# CPU seconds come from raw integer tick deltas; convert once, at the end
cpu_s=$(( (ticks_after - ticks_before) ))     # exact, no float
cpu_s=$(( cpu_s / 100 ))                       # 100 ticks = 1 s
awk -v c="$cpu_s" -v e="$elapsed" -v n="$ncpu" \
    'BEGIN { exit (c > e*n) }' || echo "*** CPU accounting broken ***"
```

Read the counters straight into shell variables. Joining `/proc` snapshots with
`awk` across files, or mixing tick units with seconds inside one `bc` expression,
produced a nonsense "511 CPU-seconds on a 16-core box" twice.

## 4b. The export and its FUSE mount

**R10 — Restarting the FUSE mount invalidates the Ganesha export.** Ganesha
resolves an export's path once, at startup, and keeps a dirfd to it. After the
FUSE mount is unmounted and remounted, that dirfd still points at the **old,
detached** mount: writes through it are accepted by the kernel page cache,
reported as success to the client, and never reach the volume server — the
`weed mount` process that owned the connection is gone.

The signature is unmistakable: a suspiciously high throughput, a client that
sees no error, and a volume `.dat` that does not grow. On 2026-11-16 this was
reproduced on purpose by restarting `seaweedfs-mount.service`: 32 MiB "written"
in 0.1 s, `dat_delta = 0`.

So any script that restarts a mount service must restart Ganesha as well, and
must prove the result with a landing check:

```bash
sudo systemctl restart seaweedfs-mount.service
# wait until the mount is back, then:
sudo systemctl restart ganesha
# and only then measure - through a landing check (R4)
```

`scripts/recover-fuse.sh` is the canonical sequence (detach → restart the mount
→ restart Ganesha → verify every export with real bytes). Use it.

## 5. fio job files

- Write the job file with a quoted heredoc and `sed` the directory in — an
  off-by-one in positional arguments makes fio treat the data directory as an
  option (`Bad option </path>`).
- `fallocate=none` for every case on the FUSE mount: fio's default `posix`
  preallocation makes the FUSE backend materialise the whole file before the
  write starts.
- `size=` big enough to be meaningful, small enough that the case finishes inside
  its timeout.

## 6. Cluster hygiene

- **One cluster at a time.** Three SeaweedFS clusters writing concurrently caused
  volume compaction storms and chunk-upload failures; the export was down for
  more than 15 minutes.
- **Compare media with two fresh clusters.** An aged cluster (volume compaction
  rewriting, tombstones) is slower than a fresh one on the *faster* device — the
  cluster state dominated the device difference and inverted the conclusion.
- **Never `weed master` with the default `-vacuumIntervalSeconds=840`** while
  benchmarking: the vacuum sweep makes the volume server compact volumes and
  resets in-flight chunk uploads. See R11 below for the mechanism and for the
  parameter's two traps.

## 7. Master startup parameters

**R11 — Every master startup script must set `-vacuumIntervalSeconds` to at least
86400, and every master script in a directory must use the same value.**

The parameter is the period of the master's automatic vacuum sweep (SeaweedFS
4.54, commit `5ef99c1d`). The default is 840 s. What that sweep does:

- `weed/topology/topology_event_handling.go` runs it in
  `for { ...; time.Sleep(vacuumInterval + jitter) }` — **the body runs before the
  first sleep**, so a freshly started master sweeps once, immediately.
- The sweep covers every volume of every collection. A volume qualifies when
  `GarbageRatio >= garbageThreshold` (default 0.3).
- Compaction is a **full rewrite** of the volume's `.dat`
  (`CompactByIndex` → `.cpd`/`.cpx`), and the commit phase holds
  `dataFileSyncLock` + `dataFileAccessLock`, so reads and writes of that volume
  block while it runs.
- `weed mount`'s chunk upload carries a stall watchdog
  (`weed/operation/upload_content.go`): on timeout it cancels the POST. The
  volume server reads that POST as multipart
  (`weed/storage/needle/needle_parse_upload.go`) and answers
  `multipart: NextPart: unexpected EOF` → HTTP 400.
- Then: volume server blocked → FUSE upload blocked → **Ganesha blocks (it has
  no write timeout)** → the NFS client on a hard mount retries forever → the
  export is down.

Two traps in the parameter itself:

- **`0` does not disable the sweep.** `vacuumInterval <= 0` is rewritten to
  14 minutes.
- The real switch is `weed shell -master=127.0.0.1:9333` →
  `volume.vacuum.disable`. It is a **runtime** flag and does not survive a
  master restart; `-vacuumIntervalSeconds` does. Use both: the flag keeps the
  post-restart sweep out of the way, the shell command stops the sweep that a
  restart triggers immediately.

Why the invariant is "every script, same value": cluster A's `master.sh` shipped
**without** the flag while `master-b.sh` and `master-nvme-fresh.sh` had it, and
`make-cluster.sh` — the generator — did not emit it either, so *every newly
created cluster came up with the 14-minute default*. The running cluster A master
carried the flag only because its process was started before the script was
rewritten; nothing failed until the next restart. A tier that sweeps every 14
minutes next to one that sweeps every 24 hours also makes any A/B comparison a
lie.

```bash
exec "$SW_BIN" master \
  -mdir="$SW_MASTER_DIR" \
  -peers=none \
  -vacuumIntervalSeconds=86400 \
  -telemetry=false
```

## 8. Shell syntax

**R12 — A comment inside a backslash-continued command truncates it.**

```bash
exec "$SW_BIN" master \
  -ip="$SW_IP" \
  # this comment sits inside the continuation
  -peers=none
```

The `\` joins the next physical line into the command; the `#` there starts a
comment that ends at the newline, so `-peers=none` is executed as a **separate
statement** — `command not found`, or worse, something else runs. `bash -n` does
not catch it, because the result is still valid syntax. Put the comment above
the command instead.

A comment line that **ends** with a backslash is *not* a continuation: inside a
comment the backslash is literal and the comment ends at the newline. Only a
code line can continue into the next one, and the linter knows that.

**An apostrophe inside an `awk '...'` program ends the program.**
`awk ' ... the bare arm's buf1M ... '` closes the shell's single-quoted string
at the apostrophe, and everything after it is parsed as **shell** — so the
script dies with `syntax error near unexpected token '('` pointing at a line
that looks perfectly innocent. The apostrophe was in a *comment inside the
awk program*, which is exactly where nobody looks for it.

Two ways out: do not use an apostrophe (`the bare arm on buf1M`), or put the
awk program in a file. And **always `bash -n` the script after editing an
embedded awk program** — the linter does not parse awk.

## 9. The containerised arms

The lab compares the same NFS-Ganesha + SeaweedFS stack in three shapes:

| arm | storage plane | FUSE gateway | Ganesha |
|---|---|---|---|
| bare metal | host systemd units | host systemd unit | host |
| Docker | container | **host** | host |
| Kubernetes | pods | **host** | host |

Ganesha and the FUSE gateway are **identical in all three**, so the only
variable is the storage backend. Anything that moves the gateway as well
changes two variables at once and the comparison stops meaning anything.

**R13 — Inside a container, bind the container's address, not 127.0.0.1.**
`127.0.0.1` inside a container is the *container's* loopback. Docker's port
proxy connects to the container's IP, so a service bound to 127.0.0.1 makes the
published port accept the TCP connection and then **reset it** — the symptom is
`connection reset by peer` on a port that is plainly LISTENing. Use
`IP=$(hostname -i | awk '{print $1}')` and `-ip="$IP" -ip.bind="$IP"`.

**R14 — Publish the gRPC port at the same offset as the HTTP port.**
SeaweedFS derives gRPC from HTTP: **grpc = http + 10000**. A client given
`127.0.0.1:19344` dials `127.0.0.1:29344`. Publish `19344:8888` *and*
`29344:18888`, and the same for the master and the volume server.

**R15 — "Is it mounted?" must check the filesystem type.**
`is_mounted` only says "something is mounted here", and a plain directory that
was bind-mounted onto itself is in `/proc/mounts` as **ext4**. That is how a
script comes to believe a FUSE mount is live when it is not, and the write
then lands in the host's own filesystem. Use `is_fuse_mounted <path> [fstype]`
from `lib-nfslab.sh`.

**R16 — The FUSE mount stays on the host.**
A FUSE mount created inside a container does **not** propagate back to the
host: the container's mount lands in another peer group (`shared:1944` inside,
`shared:1` on the host) and the propagation stops there. `mount --make-shared`
and compose's `bind.propagation: rshared` do not change that. The host then
sees an ordinary ext4 directory where the mount should be.

**R17 — `pkill` on the host reaches into containers.**
The host's `/proc` shows container processes, so `pkill -x weed` kills the
bare-metal clusters *and* the container's processes. Worse, SIGTERM is a
**clean** exit, so systemd's `Restart=on-failure` does not bring them back and
the stack stays down until it is started by hand. Kill by feature instead:
`pids_of "weed mount"` (`lib-nfslab.sh`), which scans `/proc/<pid>/cmdline` and
skips the caller's own ancestor chain.

**R18 — The container image carries the host's own binary.**
Do not pull a registry image: the version would move and every number would
become meaningless. `docker/build-image.sh` copies `/usr/local/bin/weed` (a
statically linked 4.54, commit 5ef99c1d) into the image and then checks that
the build id inside the image is the same one.

**Apply when:**
- 任何"服务在监听但连不上"的排查:先问它绑的是哪个地址(R13),再问对端端口对不对(R14)。
- 任何"写成功但后端没数据":先比对路径的 fstype(R15),再看 Ganesha 握着的 fd 指向哪个挂载实例。
- 任何在宿主上杀进程的操作:先确认容器里没有同名进程(R17)。


## 10. The Kubernetes arm

The Kubernetes arm runs the storage plane as three pods in a KIND cluster
(`kindest/node:v1.37.0`), with the FUSE gateway and Ganesha still on the
host. The addressing is the part that is easy to get wrong.

**R19 — A pod must advertise the address its CLIENT will use.**
`weed mount` does not read chunks through the filer. It asks the filer where
a chunk lives, and the filer answers with the volume server's REGISTERED
address:

```
weed/filer/reader_at.go:123     targetUrl := "http://" + volumeServerAddress + "/" + fileId
weed/topology/topology_info.go:104   Url: dn.Url()
weed/topology/data_node.go:383       dn.Url() = JoinHostPort(dn.Ip, dn.Port)
```

`dn.Ip` is the volume server's `-ip`. So the address the host's FUSE mount
fetches a chunk from is whatever `-ip` says — with a pod IP that address is
not routable from the host. The manifests therefore set `-ip` to the
**LoadBalancer address** and `-ip.bind=0.0.0.0`, because SeaweedFS keeps the
advertised address and the bind address apart:

```
weed/command/volume.go:219   -ip        the address the server REGISTERS
weed/command/volume.go:222   -ip.bind   the address it BINDS to
```

**R20 — The LoadBalancer address must be fixed, not auto-assigned.**
The pod's `-ip` is written into the manifest, so the address has to be known
before the pod starts. `spec.loadBalancerIP` pins it, and `scripts/lint-k8s-manifest.sh`
(R20/R22) rejects a Service without one, and a workload whose `-ip` is not
the address its Service hands out.

**R21 — The Service must publish the gRPC port too.**
Same rule as R14, on the Service side: a client that is given the HTTP port
dials http + 10000 for gRPC (`weed/pb/grpc_client_server.go:548`
`ServerToGrpcAddress`). A LoadBalancer Service that publishes only the HTTP
port makes the mount fail on the first gRPC call.

**R22 — The master does not keep a filer registry.**
There is no filer list in the master's topology: the filer is a CLIENT of
the master, not a member of its topology. A check that looks for the filer
in the master's status page can only ever fail. What the filer does need is
the master — it allocates every chunk through it — so that is what gets
checked, from inside the filer pod.

**R23 — The node may be a container, so the .dat size is measured from
inside the pod.**
A local-path PersistentVolume is a hostPath on the NODE. In a KIND cluster
the node is itself a Docker container, so that path does not exist on the
host: a landing check that looks for it finds nothing and reports "the
bytes did not land" for a write that landed perfectly well — a false
negative, and the one thing the check must not produce.
`scripts/k8s-volume-datsize.sh` measures it from inside the volume pod.

**R28 — A FUSE mount may live in a container only when the thing that writes
to it lives there too.**
A mount created inside a container does not propagate back to the host: it
lands in a different peer group (`shared:1944` in the container vs `shared:1`
on the host), so the host sees a plain directory and the data goes into the
host's own filesystem. That is why the Docker and Kubernetes arms keep the
FUSE gateway on the host — Ganesha runs there and has to reach the mount.

The fourth shape is the exception, and the exception is the rule: **the pod
that mounts FUSE also runs the fio that writes to it**, so the mount never
crosses a mount namespace at all. The writer and the mount are in the same
mount namespace, therefore the same one.

Two things follow from it, and both are easy to get wrong:
- "is it mounted" must check the **filesystem type**, not that the path is in
  `/proc/mounts`. A directory bind-mounted onto itself is in `/proc/mounts`
  as ext4, and a script that believes it is a FUSE mount writes to the
  host's disk and reports a landing failure.
- the landing measurement still has to come from **outside** the pod: the pod
  that writes cannot see the volume server's data directory. Measure it from
  the host, from inside the volume pod (`scripts/k8s-volume-datsize.sh`).

**Apply when:**
- 把挂载和写它的负载放进同一个容器/pod:确认 fstype 是 `fuse.seaweedfs`，不是 ext4。
- 挂载"看起来在"但数据没到后端:先比对 volume `.dat` 的**增量**与写入字节数。

## 11. The host is also the client — and a wedged write path takes the host with it

**R24 — A leftover NFS client mount is a feedback loop, not litter.**
The lab host is BOTH the NFS server and an NFS client: the benchmarks mount
the server's own exports. With `hard` mounts a leftover client retries
forever (`nfs: server 192.168.3.146 not responding, still trying`), and each
retry is another request for the server to answer. Eleven such mounts were
left behind by a heal test on 2026-11-16. `scripts/cleanup-stale-nfs-mounts.sh`
removes the self-mounts, and `scripts/arm-compare.sh` runs it before it
measures anything.

**R25 — A dead backend must be caught BEFORE the case, not after it.**
On 2026-11-16 the Docker arm's filer died. The FUSE mount kept retrying a
connection that would never come back, the write never completed, the fio
sat in D state — and the host became unusable: load average 98 on 16 cores,
and `ps` stopped working. The cause was not a slow disk: the host ran out
of memory (swap 7/7 GiB), the Go runtime's scavenger started calling
`madvise`, and a write path held `mmap_lock` in write mode, so every
`/proc/<pid>/cmdline` read — and therefore every `ps` and `pgrep -f` — blocked
behind it. `arm-compare.sh` now asks each arm's three services for their
health page before every case, and again afterwards.

**R26 — A container must watch every service it starts.**
The Docker entrypoint watched the master and the volume server but not the
filer, so a dead filer left the container "Up" and serving nothing. The
entrypoint now watches all three and exits if any of them dies, which lets
Docker's `restart: unless-stopped` bring the stack back.

**Apply when:**
- 任何"K8s 臂写不进去"的排查:先看 master 登记的 volume 地址是不是 LoadBalancer 地址(R19)。
- 任何"挂载是活的但写不动"的排查:先查挂载点的 filer/volume/master 三个 /healthz(R25)。
- 任何"整机 ps 卡住"的排查:先看 dmesg 有没有 `blocked for more than N seconds`,
  再看 `memory.events` 的 oom_kill 与 free -m 的 swap(R24/R25)。
