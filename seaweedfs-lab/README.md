# NFS-Ganesha V15.9 + SeaweedFS FUSE — performance lab

Host: `ys1000@192.168.3.146` (Ubuntu 24.04.4, 16 vCPU, 62 GiB RAM, NVMe SSD `/dev/nvme0n1p3`)

```
NFS client  ->  NFS-Ganesha V15.9 (FSAL_VFS)  ->  /home/ys1000/seaweedfs/mnt (fuse.seaweedfs)
            ->  weed filer  ->  weed volume server  ->  NVMe
```

## Results

**Tuning answers (block size, NFS mount options, CPU/RAM sizing, MDCACHE) with
measured numbers: [`RECOMMENDATIONS.md`](RECOMMENDATIONS.md).**

**Session retrospective — what broke, what it cost, and the guardrails now in
place: [`RETRO.md`](RETRO.md).**

**Rules for writing a new script here (each one is a footgun that already bit):
[`LAB-CONVENTIONS.md`](LAB-CONVENTIONS.md)**, checked mechanically by
`scripts/lint-lab-script.sh`.

Full write-IO matrix (22 cases) plus root-cause analysis: **[`RESULTS.md`](RESULTS.md)**.

SSD-vs-HDD storage-tier comparison (two fresh, byte-identical SeaweedFS clusters,
one on the NVMe, one on `/dev/sda`): **[`RESULTS-SSD-vs-HDD.md`](RESULTS-SSD-vs-HDD.md)**.

Headline numbers (512 MiB per case, fresh NVMe cluster, **every case verified to
have reached the volume server**):

| path | throughput |
|---|---|
| NFS → Ganesha → FUSE, O_DIRECT 1 MiB | **152 MiB/s** |
| NFS → Ganesha → FUSE, O_DIRECT **8 MiB** | **630 MiB/s** ← block size is a 4.1× lever on the stable-write path |
| NFS → Ganesha → FUSE, buffered + one final fsync | **697–831 MiB/s** (block size insensitive) |
| NFS → Ganesha → FUSE, buffered + fsync, **8 files in parallel** | **1145 MiB/s** |
| NFS → Ganesha → FUSE, buffered, no fsync | 1778 MiB/s (page-cache acceptance only) |
| NFS → Ganesha → local ext4 (control), O_DIRECT | 719 MiB/s |
| direct FUSE, O_DIRECT | 1932–2188 MiB/s |
| raw NVMe, O_DIRECT | 5278 MiB/s |

**The storage device only shows up on sustained writes** (the write must exceed
SeaweedFS's 4 GB write buffer to reach the platter):

| write size | NVMe tier | HDD tier |
|---|---|---|
| 512 MiB (NFS O_DIRECT) | 157 MiB/s | 154 MiB/s (−2%) |
| **6 GiB (buffered + final fsync), bytes verified on disk** | **523 MiB/s (11.7 s)** | **232 MiB/s (26.5 s)** (−56%) |

> The earlier figure for the 6 GiB row (1517 vs 93 MiB/s) was measured while the
> FUSE mount was wedged: `dat_delta_mib` was **0** for both tiers, i.e. nothing
> reached the disk. It measured write-buffer absorption, not the device.
> `scripts/sustained-v2.sh` re-measures it with a landing assertion; see
> `results/sustained-v2.csv`.

**Root cause:** Ganesha issues one `fsync(2)` per NFS WRITE when the client asks for a
stable write (`src/FSAL/FSAL_VFS/file.c:1399`, gated by `write_arg->fsal_stable`).
On a SeaweedFS FUSE mount that fsync flushes a chunk to the weed volume server and
writes filer metadata — ~150 ms each, so a 1 MiB write costs ~154 ms end to end.
The same fsync on plain ext4 costs ~1.4 ms, which is why the control export reaches
719 MiB/s with an identical workload. O_DIRECT over NFS triggers this per write;
buffered writes use `UNSTABLE` and only fsync once at the end — **5–6× faster for the
same durability.**

## Ganesha V15.9

| item | value |
|---|---|
| source tree | `/home/ys1000/src/github.com/nfs-ganesha/nfs-ganesha`, branch **`v15.9`** (tag `V15.9`, commit `42bc41b62`) |
| version string | `ganesha.nfsd -v` → `NFS-Ganesha Release = V15.9` |
| binary | `/usr/bin/ganesha.nfsd` (also `/usr/lib/libganesha_nfsd.so.15.9`) |
| FSAL module | `/usr/lib/ganesha/libfsalvfs.so` |
| config | `/etc/ganesha/ganesha.conf` |
| unit | `ganesha.service` (enabled, `Type=simple`, `-F` foreground) |
| export | `192.168.3.146:/seaweedfs` → `/home/ys1000/seaweedfs/mnt` |
| Prometheus | `http://127.0.0.1:32000/metrics` (on the server) · **`http://192.168.3.146:32000/metrics` (from another node)** |

### Scraping the metrics from another node

`127.0.0.1:32000` only exists on the server itself. From any node on the
same LAN use the server's address:

```bash
curl -s http://192.168.3.146:32000/metrics | head
```

This works because `Monitoring_Addr = 0.0.0.0` in `NFS_CORE_PARAM`, i.e. the
exporter listens on every interface. Measured from another node: HTTP 200,
894 lines, ~65 KB, 37 ms — identical to what the server sees locally, and the
`ganesha_export_metadata` series lists all four exports.

Two things worth knowing before changing it:

- **Unset is not the same as "loopback".** `Monitoring_Addr` defaults to
  `0.0.0.0`, and the startup code reads that as "not set" and falls back to
  `Bind_Addr` — which is also `0.0.0.0` by default. LAN reachability
  therefore depends on *two* defaults lining up, which is why the setting is
  now explicit.
- **Do not bind it to a specific address to narrow the exposure.** The
  exporter calls `PEXIT()` when `bind()` fails, so a missing or changed
  interface address would take Ganesha down at startup. The endpoint also
  listens on the docker bridges (`172.17.0.1`, `172.18.0.1`); if that matters,
  scope it with a firewall rule rather than with the bind address.

If the box is ever behind NAT, use an SSH tunnel instead of exposing the port:

```bash
ssh -N -L 32000:127.0.0.1:32000 ys1000@192.168.3.146
```

Build: `RelWithDebInfo`, FSAL_VFS only (all other FSALs off), monitoring on,
`USE_GSS` compiled in but disabled at runtime via `NFS_KRB5 { Active_krb5 = false; }`.
Rebuild with:

```bash
cd /home/ys1000/src/github.com/nfs-ganesha/nfs-ganesha/build && make -j16 && sudo make install
```

### Ganesha config gotchas found in V15.9

* **`Nb_Worker` does not exist.** The NFS request threads *are* the TIRPC I/O
  threads → use `RPC_Ioq_ThrdMin` (default 2) / `RPC_Ioq_ThrdMax` (default 200).
* **`-N` on the command line is the debug level, not a worker count.**
* **Log-level tokens in the config file have no `NIV_` prefix**:
  `Default_Log_Level = EVENT;` (the CLI form is `NIV_EVENT`).
* **`MNT_Point` is not a config token** (the core block has `MNT_Port`, the
  mountd port — different thing).
* **`Active_krb5` defaults to true**; with RPCSEC_GSS compiled in, Ganesha then
  aborts at startup with *"Cannot acquire credentials for principal nfs"*
  unless a keytab/KDC exists. Set `NFS_KRB5 { Active_krb5 = false; }` for an
  AUTH_SYS-only lab.
* **`-F` is mandatory under systemd.** Without it `ganesha.nfsd` forks, systemd
  sees the parent exit and SIGTERMs the still-running child → instant shutdown.
* The export uses **Root_Squash**, so a **root** NFS client is mapped to
  `nobody` and cannot write. Run the client as a normal user.
* **Parameter and block names are case-insensitive** (`Export_Defaults` ==
  `EXPORT_DEFAULTS`, `Default_log_level` == `Default_Log_Level`).

### NFSv4 minor-version pinning (v4.1 vs v4.2)

`NFSv4 { minor_versions = 0,1; }` is set in `ganesha.conf`.

* The value is a **bitmask**, `1 << minor`: bit0 = NFSv4.0, bit1 = NFSv4.1,
  bit2 = NFSv4.2 (`src/Protocols/NFS/nfs4_Compound.c:1220`).
* **V15.9 default is `NFSV4_MINOR_VERSION_ALL`** — v4.0 + v4.1 + v4.2 are all
  allowed. You have to opt *out* of v4.2 explicitly.
* With `0,1` a v4.2 client is refused with `NFS4ERR_MINOR_VERS_MISMATCH`
  (client sees *"Protocol not supported"*).

Verified on 146:

| client | result |
|---|---|
| `vers=4.1` on `192.168.3.146:/seaweedfs` | OK — 1 MiB rsize/wsize negotiated |
| `vers=4.2` on `192.168.3.146:/seaweedfs` | **refused** (as intended) |
| `vers=3` on `192.168.3.146:/home/ys1000/seaweedfs/mnt` | OK |

Note: **NFSv3 cannot use an NFSv4 pseudo path.** v4 clients use `Pseudo`
(`/seaweedfs`), v3 clients must use the real `Path`
(`/home/ys1000/seaweedfs/mnt`).

### Porting an older Ganesha config to V15.9

A production GPFS config (Ganesha 3.x/4.x era) does not transfer verbatim:

| old token | V15.9 |
|---|---|
| `nb_worker = 256` | **gone** → use `RPC_Ioq_ThrdMin` / `RPC_Ioq_ThrdMax` |
| `CacheInode { fd_hwmark_percent=…; lru_run_interval=…; entries_hwmark=… }` | **gone** → block renamed to `MDCACHE` (tokens `Dir_Chunk`, `NParts`, `Cache_Size`, `Detached_Mult`) |
| `MDCACHE { dir_chunk=128; }` | `MDCACHE { Dir_Chunk = 128; }` |
| `nfs_protocols`, `mnt_port`, `nlm_port`, `rquota_port` | still exist (same names, different case) |
| `manage_gids_expiration`, `short_file_handle`, `clustered`, `enable_nlm` | still exist (same names, different case) |
| `heartbeat_freq = 0` | only affects the **DBus** heartbeat — irrelevant with `USE_DBUS=OFF` |
| `Attr_Expiration_Time = 60` | already the V15.9 default (`EXPORT_DEFAULT_CACHE_EXPIRY`) |
| `enable_rpc_cred_fallback = false` | already the V15.9 default |
| `MaxOffsetRead/Write = 18446744073709551615` | V15.9 defaults to `INT64_MAX` — large test files (32/64/128 GiB) are fine as-is |

**MDCACHE is available** in this build (the stackable FSAL is compiled into
`libganesha_nfsd.so`), but the baseline export uses **plain `FSAL_VFS`**.
MDCACHE-wrapped VFS (`FSAL { Name = MDCACHE; FSAL { Name = VFS; } }`) is a
good *variable to measure*, not something to bake into the baseline — it adds
an inode/attr cache layer that hides real latency.

## SeaweedFS FUSE backend

| Path | Purpose |
|---|---|
| `/home/ys1000/seaweedfs/mnt` | **the FUSE mount — what Ganesha exports** |
| `/home/ys1000/seaweedfs/data` | volume server `.dat` / `.idx` chunk files |
| `/home/ys1000/seaweedfs/master` | master raft + topology metadata |
| `/home/ys1000/seaweedfs/cache` | `weed mount` chunk staging cache (write buffer) |
| `/home/ys1000/seaweedfs/scripts` | start/stop scripts + this README |
| `/home/ys1000/seaweedfs/tools` | `fio` (installed without dpkg) |
| `/home/ys1000/seaweedfs/logs` | per-service logs |

| systemd unit | process | listen |
|---|---|---|
| `seaweedfs-master.service` | `weed master` | 127.0.0.1:9333 http / 19333 grpc |
| `seaweedfs-volume.service` | `weed server -master=false` | 127.0.0.1:8081 http / 18081 grpc |
| `seaweedfs-filer.service` | `weed filer` | 127.0.0.1:8888 http / 18888 grpc |
| `seaweedfs-mount.service` | `weed mount` | FUSE mount at `/home/ys1000/seaweedfs/mnt` |

Everything binds to **loopback only** — the FUSE mount is consumed locally by
Ganesha, so this keeps the control/data plane off the NIC and out of the
measurement.

### SeaweedFS v4.x gotchas

* gRPC port = **http port + 10000**. The master address given to `weed server`
  / `weed filer` must be the **HTTP** port (`9333`); passing `19333` makes them
  dial `29333` and fail forever.
* Volume-server flags are namespaced: `-volume.max`, `-volume.port`,
  `-volume.port.grpc`, `-volume.readMode` (there is no bare `-max`).
* `weed status` does not exist in v4.54; use
  `curl http://127.0.0.1:9333/cluster/status` and `curl http://127.0.0.1:8081/status`.
* `8080` was taken on this host by `kubectl proxy`, so the volume server uses `8081`.

### `weed mount` tunables actually in use

Configured in `scripts/seaweedfs.env` / `scripts/mount.sh`:

| flag | value | note |
|---|---|---|
| `-chunkSizeLimitMB` | 2 | filer chunk size / local write buffer |
| `-writeBufferSizeMB` | 4096 | global cap on the per-mount write buffer |
| `-fuse.maxBackground` | 128 | in-flight async requests the kernel queues |
| `-fuse.congestionThreshold` | 0 | kernel derives 3/4 of max_background (= 96) |
| `-cacheDir` | `.../cache` | chunk staging cache, on the NVMe |
| `-cacheCapacityMB` | 128 | read cache capacity |
| `-metadataFlushSeconds` | 120 | periodic metadata flush to the filer |
| `-concurrentWriters` / `-concurrentReaders` | 128 | seaweedfs-internal concurrency |
| `-dlm` | on | distributed lock manager; honours POSIX advisory locks |
| `-allowOthers` | on | requires `user_allow_other` in `/etc/fuse.conf` (enabled) |

## Operations

```bash
systemctl status ganesha seaweedfs-{master,volume,filer,mount}
systemctl restart seaweedfs-mount     # remount the FUSE layer only
/home/ys1000/seaweedfs/scripts/status.sh          # processes, ports, FUSE params, cluster
/home/ys1000/seaweedfs/scripts/verify-exports.sh  # prove every export really writes (real bytes -> volume .dat)
/home/ys1000/seaweedfs/scripts/check-vacuum-state.sh  # prove no vacuum sweep can interrupt a measurement
/home/ys1000/seaweedfs/scripts/stop-all.sh        # ordered shutdown
/home/ys1000/seaweedfs/scripts/bench-fuse-baseline.sh   # FUSE-layer baseline
/home/ys1000/seaweedfs/scripts/bench-nfs-probe.sh      # NFS end-to-end probe
/home/ys1000/seaweedfs/scripts/smoke-nfs.sh             # end-to-end correctness check
```

### Deploying this tree to the lab host

```bash
bash seaweedfs-lab/scripts/deploy-lab.sh [ys1000@192.168.3.146] [/home/ys1000/seaweedfs]
```

One command, and it verifies instead of assuming: every script on the host is
compared byte-for-byte with the tree, the host's own linter has to agree, and
`check-vacuum-state.sh` has to report `PASS` before the deploy is considered
done. It also refuses to delete a script it did not write — a script that
exists on the host but not in the tree stops the deploy instead of being
removed. Hand-copying files is how the tree drifted on 2026-11-16: the masters
ran with `-vacuumIntervalSeconds=86400` while the startup script the systemd
unit actually executes did not contain it.

> **Restarting the FUSE mount invalidates the Ganesha export.**
> `systemctl restart seaweedfs-mount` unmounts and remounts the FUSE layer, but
> Ganesha resolved the export's path once, at startup, and still holds a dirfd
> to the **old, detached** mount. Writes through it are accepted by the kernel
> page cache and reported as success, and never reach the volume server — the
> `weed mount` process that owned the connection is gone. Measured 2026-11-16:
> 32 MiB "written" in 0.108 s, volume `.dat` delta **0 MiB**.
>
> **Always follow a mount restart with `systemctl restart ganesha`,** or run
> `scripts/recover-fuse.sh`, which does detach → restart mount → restart
> Ganesha → verify every export with real bytes on the volume server. It is a
> procedure, not just a crash-recovery tool.
>
> Distinguishing the two failure modes (both look like "the write succeeded"):
> a **stale export** gives an implausibly high throughput, a **wedged mount**
> gives a low one. See `RECOMMENDATIONS.md` §5.2.

Performance matrix and analysis:

```bash
/home/ys1000/seaweedfs/scripts/bench-write-io.sh     # full 22-case matrix -> logs/bench-write-io.csv
/home/ys1000/seaweedfs/scripts/render-results.sh     # CSV -> Markdown table
/home/ys1000/seaweedfs/scripts/ext4-control.sh      # local-ext4 control export (isolates FUSE)
/home/ys1000/seaweedfs/scripts/pattern-test.sh       # durability patterns (buffered vs O_DIRECT)
/home/ys1000/seaweedfs/scripts/trace-compare.sh      # strace: pwritev/fsync counts per path
```

The lab config exports a **second, control-only export** `192.168.3.146:/local-ext4`
→ `/home/ys1000/ganesha-local-ext4` (plain ext4, no FUSE). It exists purely to
separate "NFS + Ganesha" cost from "FUSE/SeaweedFS" cost — see `RESULTS.md` §3.3.
Remove it for production use.

Mount the export from a client:

```bash
mount -t nfs -o vers=4.1,proto=tcp,rsize=1048576,wsize=1048576 \
  192.168.3.146:/seaweedfs /mnt/ganesha-test
```

## Measured baselines (2026-11-16)

The full write-IO matrix (22 cases: protocol, block-size, wsize, concurrency,
persistence semantics, plus FUSE and raw-NVMe reference layers) is in
[`RESULTS.md`](RESULTS.md); raw numbers in `results/bench-write-io.csv`.

| layer | throughput |
|---|---|
| raw NVMe ext4, 1M bs, O_DIRECT | 5278 MiB/s |
| raw NVMe ext4, 1M bs, buffered | 3185 MiB/s |
| SeaweedFS FUSE, 1M bs, 1 job, O_DIRECT | **1952 MiB/s** |
| SeaweedFS FUSE, 1M bs, 1 job, buffered | 1350 MiB/s |
| SeaweedFS FUSE, 1M bs, 4 jobs, O_DIRECT | 1956 MiB/s aggregate (**no scaling**) |
| SeaweedFS FUSE, 1M bs, fdatasync per write | **64.7 MiB/s** |
| NFSv4.1 buffered (1M r/w) | 2547 MiB/s (cache acceptance, not persistence) |
| NFSv4.1 buffered + one final fsync | **636 MiB/s** (2 GiB) / **507 MiB/s** (8 GiB) |
| NFSv4.1 **O_DIRECT** (1M r/w) | **104 MiB/s** (true synchronous path) |
| NFSv3 **O_DIRECT** (1M r/w) | 104 MiB/s (same path — protocol makes no difference) |

Conclusions that shape the architecture:

1. **The FUSE write path does not scale with concurrency.** 1 / 4 / 8 direct writers
   all land at ~1.95 GiB/s aggregate — the bandwidth is just divided. The bottleneck
   is the FUSE/SeaweedFS layer, not Ganesha and not the network.
2. **Durability is what costs.** The mechanism is now known exactly: Ganesha calls
   `fsync(2)` after every stable WRITE, and on SeaweedFS FUSE that flush costs
   ~150 ms. Use buffered writes + one explicit fsync at the end rather than O_DIRECT.
3. **Concurrency across *different files* does scale** through the NFS path
   (101 → 279 → 473 → 761 MiB/s for 1/2/4/8 jobs), because each file gets its own
   fsync slot. Concurrency *within* one file does not.
4. **Block size matters linearly** (128k→23.7, 256k→44.7, 512k→66.1, 1M→101 MiB/s)
   because it directly sets the number of fsyncs per byte. Client-side `wsize`
   tuning is worthless on its own — the same curve appears when only `bs` changes.
5. `RPC_Ioq_ThrdMin/Max` are **not** the lever: 16 WRITEs were already in flight
   at once while Ganesha used 6.5% of one core.

Since the host uplink is 1 GbE (~117 MB/s ceiling), the network is the next
constraint after the FUSE layer.

> All measurements use a **local client on the same host**: NFS traffic uses the
> local `br0` address (kernel TCP stack) and never crosses the 1 GbE NIC.
> A remote client at `192.168.3.134` was unreachable (SSH timeout), so cross-host
> numbers could not be measured.

## Host issues that were fixed / worked around

* **SeaweedFS's 14-minute automatic vacuum sweep can take the whole NFS export
  down.** `weed master` defaults to `-vacuumIntervalSeconds=840`; a sweep stops
  and compacts volumes, which resets in-flight chunk uploads
  (`multipart: NextPart: unexpected EOF`, HTTP 400). The FUSE mount then blocks,
  Ganesha's write blocks (it has no write timeout), and the hard-mounted NFS
  client retries forever. Measured: the export was unusable for >15 minutes.
  **All three masters now run with `-vacuumIntervalSeconds=86400`.**
* **A dead FUSE mount stays in `/proc/mounts` but returns ENOTCONN (107).**
  `weed mount` then cannot re-mount (mount point occupied) and Ganesha
  *silently drops* that export at startup. Never use `/proc/mounts` to decide
  whether a FUSE mount is usable — actually `stat` it. See `scripts/fix-fuse.sh`.
* **NFS hard mounts block in `umount(2)` and in `stat(2)`.** `mountpoint -q`
  calls `stat`, so it hangs on a wedged client; `umount` on a client whose
  server-side path vanished sits in uninterruptible sleep and cannot be killed.
  Use `/proc/mounts` for mount checks, always `umount -l`, and never unmount
  synchronously in a harness.
* **Ganesha V15.9 segfaulted on startup (upstream bug, locally patched).**
  With `Enable_Metrics = true` and `Enable_Dynamic_Metrics = false`,
  `ganesha.nfsd` crashed with SIGSEGV 3–15 s after start and then crash-looped.
  `src/MainNFSD/nfs_main.c` only calls `dynamic_metrics__init()` when dynamic
  metrics are enabled, but the Prometheus exporter starts regardless — so the global
  `std::unique_ptr<DynamicMetrics>` stays NULL, and
  `dynamic_metrics_export_info()` (`src/monitoring/dynamic_metrics.cc:527`) is the
  only function in that file missing the `if (!dynamic_metrics) return;` guard its
  siblings have. Fix is one line; patch in
  `patches/0001-monitoring-fix-null-deref-in-dynamic_metrics_export_info.patch`.
  After rebuilding: 120 s stable with `NRestarts=0`, and the whole 22-case matrix
  ran without a single crash. The fix is now also a pull request on the fork
  ([PR #1](https://github.com/jibudata/nfs-ganesha/pull/1)), together with a
  CI workflow that builds the tree and checks the formatting of the lines a
  branch changed ([PR #2](https://github.com/jibudata/nfs-ganesha/pull/2)) —
  both jobs are green on GitHub Actions.
* **`apt` was wedged for 12 days.** A hung `unattended-upgrade` (pid 206491)
  held `/var/lib/dpkg/lock-frontend`, and an orphaned `needrestart`/`debconf`
  tree held `/var/cache/debconf/config.dat`. Both trees were killed, then
  `apt-get --fix-broken install` completed the stale `libc6` security upgrade
  (2.39-0ubuntu8.9 → .12). `apt` is healthy again; `apt-daily*.timer` and
  `unattended-upgrades.service` are intact.
* `fio` was installed **without touching dpkg** (`apt-get download` +
  `dpkg-deb -x` into `/home/ys1000/seaweedfs/tools`), because the Ubuntu build
  links gluster's `libgfapi` / `libnbd` / `libglusterfs` / `libgfrpc` /
  `libgfxdr`. `/usr/local/bin/fio` is a wrapper that sets `LD_LIBRARY_PATH`.
* **`df` can hang** on this host (NFS hard mount). Use
  `stat -f -c "%b %a %S" <path>` or `df -h <path>` on a non-NFS path instead.
