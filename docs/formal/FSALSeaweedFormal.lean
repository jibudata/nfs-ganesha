/-
  FSAL_SEAWEED v0.3.4 — Formal Verification Root Module (FM-01 .. FM-07)
  Pure Lean 4 (zero Mathlib required, zero `sorry`, zero `admit`, zero custom axioms).

  Run `./verify.sh` in `docs/formal/` to execute:
    1. Full `lake build` compilation of all 7 modules
    2. Source escape scan (`sorry` / `admit` / `axiom`)
    3. Automated `#print axioms` whitelist gate (propext / Quot.sound / Classical.choice only)
-/

import FSALSeaweedFormal.Arena
import FSALSeaweedFormal.DirtyPageMap
import FSALSeaweedFormal.AsyncLifecycle
import FSALSeaweedFormal.DurabilityEpoch
import FSALSeaweedFormal.ChunkOrdering
import FSALSeaweedFormal.ObjectIdentity
import FSALSeaweedFormal.FilerCAS

-- Axiom Audit: every core theorem MUST depend ONLY on Lean's standard logical kernel
-- (`propext`, `Quot.sound`, `Classical.choice`, or empty — ZERO `sorryAx`, ZERO custom axioms!)

-- FM-01: Arena (Tokenized Dual RefCount & Global Pool Isolation)
#print axioms FSALSeaweedFormal.Arena.no_free_while_pinned_or_owned
#print axioms FSALSeaweedFormal.Arena.owner_token_isolation
#print axioms FSALSeaweedFormal.Arena.worker_pin_token_isolation
#print axioms FSALSeaweedFormal.Arena.permanent_aba_immunity
#print axioms FSALSeaweedFormal.Arena.pool_capacity_partition
#print axioms FSALSeaweedFormal.Arena.allocUnstablePool_isolates_reserves
#print axioms FSALSeaweedFormal.Arena.allocStablePool_policy
#print axioms FSALSeaweedFormal.Arena.allocReadPool_isolates_writes
#print axioms FSALSeaweedFormal.Arena.sequential_alloc_no_duplicate_slotId

-- FM-02: DirtyPageMap (Byte-Range Partial Overwrite, Non-Aliasing & Sync Inflight Protection)
#print axioms FSALSeaweedFormal.DirtyPageMap.partial_overwrite_byte_semantics
#print axioms FSALSeaweedFormal.DirtyPageMap.write_never_overwrites_or_mutates_inflight
#print axioms FSALSeaweedFormal.DirtyPageMap.runPageMap_preserves_all_invariants
#print axioms FSALSeaweedFormal.DirtyPageMap.writable_and_inflight_physically_distinct
#print axioms FSALSeaweedFormal.DirtyPageMap.finishUpload_blocked_while_pinned_or_undetermined

-- FM-03: AsyncLifecycle (Worker PinToken Pairing & 3-State Request Completion)
#print axioms FSALSeaweedFormal.AsyncLifecycle.callback_at_most_once
#print axioms FSALSeaweedFormal.AsyncLifecycle.completing_blocks_watchdog_and_non_winners
#print axioms FSALSeaweedFormal.AsyncLifecycle.worker_pin_isolation_in_async
#print axioms FSALSeaweedFormal.AsyncLifecycle.no_recycle_while_pinned_or_owned

-- FM-04: DurabilityEpoch (Explicit COMMIT Responses & Symmetric Multi-Export Verifier)
#print axioms FSALSeaweedFormal.DurabilityEpoch.incomplete_durability_commit_returns_delay
#print axioms FSALSeaweedFormal.DurabilityEpoch.purged_loss_commit_exposes_mismatch
#print axioms FSALSeaweedFormal.DurabilityEpoch.zero_silent_data_loss_all_traces

-- FM-05: ChunkOrdering (Monotonic Generator & Chunk Resolution Ordering Theorem)
#print axioms FSALSeaweedFormal.ChunkOrdering.generator_guarantees_seq_ts_equivalence
#print axioms FSALSeaweedFormal.ChunkOrdering.older_write_never_overwrites_newer_write
#print axioms FSALSeaweedFormal.ChunkOrdering.out_of_order_upload_swap_invariant
#print axioms FSALSeaweedFormal.ChunkOrdering.cross_file_isolation
#print axioms FSALSeaweedFormal.ChunkOrdering.chunk_resolution_ordering_theorem

-- FM-06: ObjectIdentity (Immutable ObjectID, nlink/path Consistency & Open-Unlink)
#print axioms FSALSeaweedFormal.ObjectIdentity.object_lifecycle_safety

-- FM-07: FilerCAS (Concurrent Multi-Actor CAS Retry State Machine & Delta Idempotency)
#print axioms FSALSeaweedFormal.FilerCAS.flush_delta_idempotent
#print axioms FSALSeaweedFormal.FilerCAS.truncate_delta_semantics
#print axioms FSALSeaweedFormal.FilerCAS.cas_attempts_non_interference
#print axioms FSALSeaweedFormal.FilerCAS.concurrent_cas_trace_safety
#print axioms FSALSeaweedFormal.FilerCAS.quiescent_retry_converges
