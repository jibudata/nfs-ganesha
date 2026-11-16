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
  resets in-flight chunk uploads.
