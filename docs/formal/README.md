# FSAL_SEAWEED v0.3.4 — Formal Verification Package (`FM-01` .. `FM-07`)

Pinned Repository Baselines:
- **NFS-Ganesha**: `dev-V15.9` (`42bc41b62c12346aea30357cb613944e1032890b`)
- **SeaweedFS**: `dev-4.48` (`530be3e37337488ecc34d58441e0bc476e121c93`)
- **Lean Toolchain**: `leanprover/lean4:v4.14.0` (pure Lean 4, zero Mathlib dependency)

## 1. v0.3.3 -> v0.3.4 Review Resolution Summary

| Module | File | v0.3.3 Review Findings Fixed in v0.3.4 |
| --- | --- | --- |
| **FM-01** | [Arena.lean](FSALSeaweedFormal/Arena.lean) | **P0**: Replaced anonymous ref counts with registered `OwnerToken` / `PinToken` sets proving double-drop/double-unpin safety and cross-owner/cross-worker isolation; added `addOwner` to `permanent_aba_immunity`; added global `ArenaPool` finite-capacity partition, `allocStablePool` normal-first priority & exhaustion handling, `readReserve` isolation, and physical `slotId` non-aliasing across sequential allocations. |
| **FM-02** | [DirtyPageMap.lean](FSALSeaweedFormal/DirtyPageMap.lean) | **P0-1**: `FILE_SYNC` NEVER overwrites an active `inflightSlot` (returns `.backpressure` when `inflightSlot.isSome`); `write_never_overwrites_or_mutates_inflight` holds for ALL writes (async & sync). **P0-2**: Enforced & proved `distinctPhysicalSlot` (`ws.slotId ≠ inf.slotId`) across all traces. **P0-3**: Replaced scalar `Nat` with byte-level `PageBytes := Nat → Nat` proving exact partial overwrite semantics on `[offset, offset + length)`. **P0-4**: Bijective 4-state `PageState` matching `(writableSlot, inflightSlot)`, plus tokenized worker pin/unpin & finalized `UploadOutcome` gating `finishUpload`. |
| **FM-03** | [AsyncLifecycle.lean](FSALSeaweedFormal/AsyncLifecycle.lean) | **P0**: Worker identity (`workerId`) + `PinToken` pairing proving worker isolation (`worker_pin_isolation_in_async`). **P1**: Explicit 3-state `submitted → completing → completed` with `completer` exclusivity (`completing_blocks_watchdog_and_non_winners`), callback failure cleanup semantics, and explicit `initAsyncState_inv`. |
| **FM-04** | [DurabilityEpoch.lean](FSALSeaweedFormal/DurabilityEpoch.lean) | **P0**: Explicit `CommitResult := commitOk (verifier) \| delay \| ioError` proving `.volumeDurable` (without Filer commit) and volatile states return `.delay`, and `.purgedLost` exposes verifier mismatch. **P1**: Fully symmetric 6-state lifecycle + independent `irrecoverableLoss` for BOTH Export A & Export B. |
| **FM-05** | [ChunkOrdering.lean](FSALSeaweedFormal/ChunkOrdering.lean) | **P0**: Explicit per-file generator `FileSeqState` (`nextTs = max wallClockNs (lastTsNs + 1)`) PROVING `w1.writeSeq < w2.writeSeq ↔ w1.modifiedTsNs < w2.modifiedTsNs` and deriving `StrictlyIncreasingTs` without external premises. **P1**: `fileId` scoping + `cross_file_isolation`, verified against SeaweedFS 4.48 `weed/filer/filechunks_read.go:10-96` & `filechunks.go:66-89`, accurately titled `chunk_resolution_ordering_theorem`. |
| **FM-06** | [ObjectIdentity.lean](FSALSeaweedFormal/ObjectIdentity.lean) | **P1**: Strengthened `ObjInv` with `PathIdsUnique`, `paths.length = obj.nlink`, and `reclaimed = true → nlink = 0 ∧ openRefs = 0 ∧ paths = []`. |
| **FM-07** | [FilerCAS.lean](FSALSeaweedFormal/FilerCAS.lean) | **P0**: Rewrote retry model as a real multi-actor concurrent state machine (`CasEvent`) allowing arbitrarily many `PRECONDITION_FAILED` conflicts under concurrent `externalChmod`/`externalChown`/`externalAppendChunk`; separated Safety (`concurrent_cas_trace_safety`) from Quiescent Liveness (`quiescent_retry_converges`); added chunk `fid` uniqueness & idempotency (`flush_delta_idempotent`), `removeFids`, and `truncateSize`; verified against SeaweedFS 4.48 `weed/server/filer_grpc_server_condition.go:86-93` & `filer_grpc_server.go:679-755`. |

## 2. SeaweedFS 4.48 Source Code Verification Citations

1. **`IF_ENTRY_EQUAL` (`weed/server/filer_grpc_server_condition.go:86-93`, `filer_grpc_server.go:679-755`)**:
   - Conditional `UpdateEntry` routes to the ring-owner Filer (`forwardToWriteOwner`), acquires exclusive per-path lock `entryLockTable.AcquireLock`, reads the stored entry, and evaluates `proto.Equal(current.ToProtoEntry(), filer.FromPbEntry("", c.ExpectedEntry).ToProtoEntry())`.
   - Compares full normalized protobuf Entry (attributes, extended attributes, chunks, hardlink fields). Mismatch returns gRPC `codes.FailedPrecondition`.
   - Post-CAS `cleanupChunks` (`filer_grpc_server.go:787-825`) runs `MinusChunks` + `CompactFileChunks` + `MaybeManifestize` and deletes covered garbage chunks.
2. **Chunk Read Resolution (`weed/filer/filechunks_read.go:10-96`, `filechunks.go:66-89`)**:
   - `readResolvedChunks` sorts start/end points by `(x, ts, isStart)` independent of chunk slice order and selects `queue.Back()` (maximum `ModifiedTsNs`) at every offset.
   - **Verified 4.48 edge case (`filechunks_read.go:68-78`)**: equal `ModifiedTsNs` causes the second overlapping chunk not to be inserted into `queue` and its end-point to remove the first chunk -> requires `INV-CHUNK-STRICT-TS`, which `FileSeqState` enforces unconditionally via `nextTs = max(wallClockNs, lastTsNs + 1)`.

## 3. Formal Invariant -> C/Go Implementation -> Runtime Test Mapping

| Formal Invariant (Lean 4) | C/Go Implementation Anchor | Runtime / Stress Test Gate |
| --- | --- | --- |
| **FM-01**: `no_free_while_pinned_or_owned`, `owner_token_isolation`, `worker_pin_token_isolation`, `permanent_aba_immunity`, `allocUnstablePool_isolates_reserves`, `allocStablePool_policy`, `sequential_alloc_no_duplicate_slotId` | C `sw_arena_slot_t` (`owner_tokens` / `pin_tokens` + `generation` atomic + 3-pool free rings `normal` / `stable_rsv` / `read_rsv` + `sw_slot_pin`/`sw_slot_unpin` ABI) | Multi-worker duplicate-release/ABA fuzzing + ASAN/TSAN stress + reserve exhaustion test under 80% normal saturation |
| **FM-02**: `partial_overwrite_byte_semantics`, `write_never_overwrites_or_mutates_inflight`, `writable_and_inflight_physically_distinct`, `runPageMap_preserves_all_invariants`, `finishUpload_blocked_while_pinned_or_undetermined` | C `sw_dirty_page_map` (`writable_slot` vs `inflight_slot` distinct `slot_id`, `FILE_SYNC` backpressure `ERR_FSAL_DELAY` while `inflight_slot != NULL`, COW new slot allocation on concurrent write during upload, `written_intervals` sub-interval seal) | Concurrent partial overwrite + `FILE_SYNC` during active upload + byte-level SHA256 verification + `TestModel9_V034_SyncInflightProtectionAndNonAliasing` |
| **FM-03**: `callback_at_most_once`, `completing_blocks_watchdog_and_non_winners`, `worker_pin_isolation_in_async`, `no_recycle_while_pinned_or_owned` | C `sw_async_req_t` atomic CAS `SUBMITTED -> COMPLETING -> COMPLETED` (`done_cb` winner exclusivity) decoupled from `sw_arena_slot_t` worker `PinToken` release (`defer recover()` in Go) | Watchdog timeout race vs. slow/panicking Go worker stress test (verify `done_cb_count == 1` and 0 UAF under ASAN) |
| **FM-04**: `incomplete_durability_commit_returns_delay`, `purged_loss_commit_exposes_mismatch`, `zero_silent_data_loss_all_traces` | Process-global `g_server_durability_epoch` (`NFS3_write_verifier` / NFSv4 `writeverf`), Volume upload `?fsync=true` + Filer publish two-phase commit, `ERR_FSAL_DELAY` on incomplete durability | Fault-injection test: kill Volume/Filer mid-upload, force volatile purge on Export A while committing Export B, assert client dirty replay & zero silent loss |
| **FM-05**: `generator_guarantees_seq_ts_equivalence`, `older_write_never_overwrites_newer_write`, `out_of_order_upload_swap_invariant`, `cross_file_isolation`, `chunk_resolution_ordering_theorem` | Per-file monotonic `write_seq` + `modified_ts_ns = max(now_ns, last_ts_ns + 1)` assigned under C file lock before upload dispatch | Concurrent overlapping random-offset writes with artificial out-of-order upload delays & NTP clock-step injection, comparing reads against POSIX oracle |
| **FM-06**: `object_lifecycle_safety` (`objectId` immutable, `nlink == paths.length`, `openRefs > 0 -> !reclaimed`, `reclaimed -> nlink=0 ∧ openRefs=0 ∧ paths=[]`) | Immutable 128-bit `Entry.Extended["nfs.object_id"]`, Filer KV `oid -> path` index, `.nfs_orphans/` open-unlink staging + post-Grace orphan sweeper | HardLink create/unlink while open + `unlink` open file + read/write via open FH + server restart Grace recovery test |
| **FM-07**: `flush_delta_idempotent`, `truncate_delta_semantics`, `cas_attempts_non_interference`, `concurrent_cas_trace_safety`, `quiescent_retry_converges` | Go Filer client `UpdateEntry` with `WriteCondition_IF_ENTRY_EQUAL`, conflict retry loop (re-read latest + re-apply deduplicated `EntryDelta`), `fid`-based chunk deduplication | Parallel `dd`/streaming writes + `chmod`/`chown`/`truncate` storm + duplicate RPC timeout replay test verifying zero lost chunks or attribute clobbers |

## 4. Reproducible Verification Commands (CI & Local Docker)

### A. Lean 4 Mechanical Compilation + Automated Axiom Whitelist Gate (`./verify.sh`)

```bash
# Native Lean 4 (requires elan / leanprover/lean4:v4.14.0):
cd docs/formal
./verify.sh

# Or via Docker Desktop (mounting docs/formal into a Lean 4 container):
docker run --rm --platform linux/amd64 \
  -v "$(pwd)/docs/formal:/work" -w /work \
  leanprovercommunity/lean4:latest \
  bash -lc './verify.sh'
```

`verify.sh` enforces ALL FOUR CI gates and exits non-zero on any failure:
1. Prints exact `lean --version` and `lake --version`
2. Scans `FSALSeaweedFormal/` rejecting any `sorry`, `admit`, or `axiom`
3. Runs `lake clean && lake build`
4. Runs `lake env lean FSALSeaweedFormal.lean` and validates via Python that EVERY ONE of the 32 core theorems appears in `#print axioms` output and depends ONLY on Lean's approved standard kernel whitelist (`propext`, `Classical.choice`, `Quot.sound`).

### B. Executable Go Exhaustive State-Space Model Checker (Models 1..9)

```bash
cd docs/formal
go test -v model_checker_test.go
```
