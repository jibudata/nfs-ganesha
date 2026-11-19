/-
  FM-05: Per-File Monotonic Timestamp Generation & Chunk Resolution Ordering Theorem (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Source-Verified SeaweedFS 4.48 Semantics (`weed/filer/filechunks_read.go:10-96` & `filechunks.go:66-89`):
    - `readResolvedChunks` converts every chunk to start/end `Point`s and sorts them by
      `(x, ts, isStart)` — independent of input slice order when `ModifiedTsNs` values are distinct.
    - At every byte offset `x`, the active visible chunk is `queue.Back()` (the covering chunk with
      strictly maximum `ModifiedTsNs`).
    - CRITICAL 4.48 EDGE CASE (`filechunks_read.go:68-78`): if two overlapping chunks share EQUAL
      `ModifiedTsNs`, the second chunk is NOT inserted into `queue` and its end-point removes the
      first chunk! Thus `INV-CHUNK-STRICT-TS` (strictly monotonic per-file `ModifiedTsNs`) is
      REQUIRED for exact equivalence with `resolveFileAt`.

  Addresses ALL v0.3.3 Review P0 & P1 Findings for FM-05:
    1. P0 FIX (Proves `writeSeq < → modifiedTsNs <` From an Explicit Generator!):
       - Models per-file `FileSeqState` with `emitChunk` computing:
           `nextSeq := lastSeq + 1`, `nextTs := max wallClockNs (lastTsNs + 1)`.
       - PROVES (even under backwards NTP jumps or identical wall-clock nanoseconds!) that for
         EVERY sequence of generated writes, `w1.writeSeq < w2.writeSeq ↔ w1.modifiedTsNs < w2.modifiedTsNs`
         and `StrictlyIncreasingFrom 0 emitted` holds AUTOMATICALLY (derived, NOT assumed!).
    2. P1 FIX (`fileId` Scoping & Honest Theorem Naming):
       - `resolveFileAt` and `posixEvalFileAt` filter by `fileId`, proving cross-file isolation.
       - Main theorem accurately named `chunk_resolution_ordering_theorem` (covering chunk-resolution
         ordering & upload-permutation invariance; concurrent Filer CAS publication is proved in FM-07).
-/

namespace FSALSeaweedFormal.ChunkOrdering

structure ChunkWrite where
  fileId       : Nat
  writeSeq     : Nat -- Per-file strictly monotonic sequence assigned at C write2
  modifiedTsNs : Nat -- Strictly monotonic timestamp assigned to filer_pb.FileChunk
  offset       : Nat
  length       : Nat
  val          : Nat -- Abstract byte value written across `[offset, offset + length)`
  deriving DecidableEq, Repr

/-- Input request fed to a file's per-file sequence/timestamp generator. -/
structure WriteReq where
  wallClockNs : Nat -- Unconstrained wall-clock reading (may go backwards or repeat!)
  offset      : Nat
  length      : Nat
  val         : Nat
  deriving DecidableEq, Repr

/-- Per-file monotonic sequence & timestamp generator (`INV-CHUNK-STRICT-TS` enforcer). -/
structure FileSeqState where
  fileId   : Nat
  lastSeq  : Nat
  lastTsNs : Nat
  emitted  : List ChunkWrite -- Logical emission order (oldest -> newest)
  deriving DecidableEq, Repr

def initFileSeq (fid : Nat) : FileSeqState :=
  { fileId := fid, lastSeq := 0, lastTsNs := 0, emitted := [] }

/-- Assign both `writeSeq` and `modifiedTsNs` atomically per file:
    `nextTs = max wallClockNs (lastTsNs + 1)` guarantees strictly increasing timestamps
    even if wall-clock time regresses or two writes happen in the same nanosecond! -/
def emitChunk (st : FileSeqState) (req : WriteReq) : FileSeqState :=
  let nextSeq := st.lastSeq + 1
  let nextTs  := max req.wallClockNs (st.lastTsNs + 1)
  let c : ChunkWrite := {
    fileId       := st.fileId,
    writeSeq     := nextSeq,
    modifiedTsNs := nextTs,
    offset       := req.offset,
    length       := req.length,
    val          := req.val
  }
  { st with
    lastSeq  := nextSeq,
    lastTsNs := nextTs,
    emitted  := st.emitted ++ [c] }

def emitAll (st : FileSeqState) (reqs : List WriteReq) : FileSeqState :=
  reqs.foldl emitChunk st

def coversFile (fid : Nat) (c : ChunkWrite) (pos : Nat) : Bool :=
  decide (c.fileId = fid ∧ c.offset ≤ pos ∧ pos < c.offset + c.length)

/-- Winner selection between two candidate `(ts, val)` reads: strictly higher `ts` wins. -/
def pickNewer (a b : Option (Nat × Nat)) : Option (Nat × Nat) :=
  match a, b with
  | none, x => x
  | x, none => x
  | some (ts1, v1), some (ts2, v2) =>
      if ts1 < ts2 then some (ts2, v2) else some (ts1, v1)

/-- SeaweedFS 4.48 `readResolvedChunks` semantic model for file `fid` at offset `pos`
    (valid under `INV-CHUNK-STRICT-TS`, where all chunks of `fid` have distinct `modifiedTsNs`). -/
def resolveFileAt (fid : Nat) (chunks : List ChunkWrite) (pos : Nat) : Option (Nat × Nat) :=
  chunks.foldl (fun acc c =>
    if coversFile fid c pos then pickNewer acc (some (c.modifiedTsNs, c.val)) else acc
  ) none

/-- Sequential POSIX reference semantics for file `fid` at offset `pos`. -/
def posixEvalFileAt (fid : Nat) (logicalLog : List ChunkWrite) (pos : Nat) : Option (Nat × Nat) :=
  logicalLog.foldl (fun acc c =>
    if coversFile fid c pos then some (c.modifiedTsNs, c.val) else acc
  ) none

/-- Strictly increasing `modifiedTsNs` predicate. -/
def StrictlyIncreasingTs (bound : Nat) : List ChunkWrite → Prop
  | []      => True
  | c :: cs => bound < c.modifiedTsNs ∧ StrictlyIncreasingTs c.modifiedTsNs cs

/-- Generator Invariant:
    1. Every emitted chunk has `fileId = st.fileId`, `writeSeq ≤ lastSeq`, `modifiedTsNs ≤ lastTsNs`.
    2. `emitted` has strictly increasing `modifiedTsNs` from `0`.
    3. Every pair in `emitted` satisfies `w1.writeSeq < w2.writeSeq ↔ w1.modifiedTsNs < w2.modifiedTsNs`! -/
def FileSeqInv (st : FileSeqState) : Prop :=
  (∀ c, c ∈ st.emitted → c.fileId = st.fileId ∧ c.writeSeq ≤ st.lastSeq ∧ c.modifiedTsNs ≤ st.lastTsNs) ∧
  StrictlyIncreasingTs 0 st.emitted ∧
  (∀ c1 c2, c1 ∈ st.emitted → c2 ∈ st.emitted →
    (c1.writeSeq < c2.writeSeq ↔ c1.modifiedTsNs < c2.modifiedTsNs))

theorem strictlyIncreasingTs_append_singleton
    (cs : List ChunkWrite) (c : ChunkWrite) (b maxTs : Nat)
    (hInc : StrictlyIncreasingTs b cs)
    (hBound : ∀ x, x ∈ cs → x.modifiedTsNs ≤ maxTs)
    (hGtB : b < c.modifiedTsNs)
    (hGtMax : maxTs < c.modifiedTsNs) :
    StrictlyIncreasingTs b (cs ++ [c]) := by
  induction cs generalizing b with
  | nil =>
      exact ⟨hGtB, trivial⟩
  | cons x rs ih =>
      rcases hInc with ⟨hBx, hRsInc⟩
      refine ⟨hBx, ?_⟩
      apply ih x.modifiedTsNs hRsInc
      · intro y hy; exact hBound y (List.Mem.tail _ hy)
      · have hxLe := hBound x (List.Mem.head _); omega

theorem emitChunk_preserves_inv (st : FileSeqState) (req : WriteReq) (hInv : FileSeqInv st) :
    FileSeqInv (emitChunk st req) := by
  rcases hInv with ⟨hBounds, hInc, hOrder⟩
  dsimp [emitChunk, FileSeqInv]
  have hTsGt : st.lastTsNs < max req.wallClockNs (st.lastTsNs + 1) := by
    have hGe : st.lastTsNs + 1 ≤ max req.wallClockNs (st.lastTsNs + 1) := Nat.le_max_right _ _
    omega
  refine ⟨?_, ?_, ?_⟩
  · intro c hc
    rcases List.mem_append.mp hc with hOld | hNew
    · have ⟨hf, hs, ht⟩ := hBounds c hOld
      exact ⟨hf, by omega, by omega⟩
    · simp at hNew
      subst hNew
      exact ⟨rfl, Nat.le_refl _, Nat.le_refl _⟩
  · exact strictlyIncreasingTs_append_singleton st.emitted
      { fileId := st.fileId, writeSeq := st.lastSeq + 1,
        modifiedTsNs := max req.wallClockNs (st.lastTsNs + 1),
        offset := req.offset, length := req.length, val := req.val }
      0 st.lastTsNs hInc (fun x hx => (hBounds x hx).2.2) (by dsimp only; omega) hTsGt
  · intro c1 c2 hc1 hc2
    rcases List.mem_append.mp hc1 with h1Old | h1New <;>
    rcases List.mem_append.mp hc2 with h2Old | h2New
    · exact hOrder c1 c2 h1Old h2Old
    · simp at h2New; subst h2New
      have ⟨_, hs1, ht1⟩ := hBounds c1 h1Old
      dsimp only
      constructor <;> intro _ <;> omega
    · simp at h1New; subst h1New
      have ⟨_, hs2, ht2⟩ := hBounds c2 h2Old
      dsimp only
      constructor <;> intro h <;> omega
    · simp at h1New h2New; subst h1New; subst h2New
      constructor <;> intro h <;> omega

/-- THEOREM FM-05.1 (P0: Explicit Generator Derives `writeSeq < ↔ modifiedTsNs <` & `INV-CHUNK-STRICT-TS`!):
    For ANY sequence of write requests (even with arbitrary/regressing wall-clock values),
    the per-file generator GUARANTEES:
      1. `w1.writeSeq < w2.writeSeq ↔ w1.modifiedTsNs < w2.modifiedTsNs`
      2. `StrictlyIncreasingTs 0 emitted` (NO equal timestamps possible -> 4.48 drop bug impossible!) -/
theorem generator_guarantees_seq_ts_equivalence (fid : Nat) (reqs : List WriteReq) :
    FileSeqInv (emitAll (initFileSeq fid) reqs) := by
  have hInit : FileSeqInv (initFileSeq fid) := by
    refine ⟨(by intro _ h; cases h), trivial, (by intro _ _ h; cases h)⟩
  have hInd : ∀ st xs, FileSeqInv st → FileSeqInv (emitAll st xs) := by
    intro st xs
    induction xs generalizing st with
    | nil => intro h; exact h
    | cons r rs ih => intro h; exact ih (emitChunk st r) (emitChunk_preserves_inv st r h)
  exact hInd (initFileSeq fid) reqs hInit

theorem pickNewer_comm_distinct (ts1 v1 ts2 v2 : Nat) (hNe : ts1 ≠ ts2) :
    pickNewer (some (ts1, v1)) (some (ts2, v2)) = pickNewer (some (ts2, v2)) (some (ts1, v1)) := by
  dsimp [pickNewer]
  by_cases hLt : ts1 < ts2
  · have hNotGt : ¬(ts2 < ts1) := by omega
    rw [if_pos hLt, if_neg hNotGt]
  · have hGt : ts2 < ts1 := by omega
    rw [if_neg hLt, if_pos hGt]

theorem pickNewer_assoc_distinct (acc : Option (Nat × Nat)) (c1 c2 : ChunkWrite)
    (hNe : c1.modifiedTsNs ≠ c2.modifiedTsNs) :
    pickNewer (pickNewer acc (some (c1.modifiedTsNs, c1.val))) (some (c2.modifiedTsNs, c2.val)) =
    pickNewer (pickNewer acc (some (c2.modifiedTsNs, c2.val))) (some (c1.modifiedTsNs, c1.val)) := by
  cases acc with
  | none =>
      dsimp [pickNewer]
      exact pickNewer_comm_distinct c1.modifiedTsNs c1.val c2.modifiedTsNs c2.val hNe
  | some p =>
      rcases p with ⟨ts0, v0⟩
      dsimp [pickNewer]
      by_cases h01 : ts0 < c1.modifiedTsNs <;>
      by_cases h02 : ts0 < c2.modifiedTsNs <;>
      by_cases h12 : c1.modifiedTsNs < c2.modifiedTsNs
      all_goals
        try omega
      all_goals
        first
        | (have h21 : ¬(c2.modifiedTsNs < c1.modifiedTsNs) := by omega
           simp [pickNewer, h01, h02, h12, h21])
        | (have h21 : c2.modifiedTsNs < c1.modifiedTsNs := by omega
           simp [pickNewer, h01, h02, h12, h21])

/-- THEOREM FM-05.2 (Global Invariant 3 — Older Overlapping Write NEVER Overwrites Newer Write): -/
theorem older_write_never_overwrites_newer_write
    (fid : Nat) (w1 w2 : ChunkWrite) (pos : Nat)
    (hCov1 : coversFile fid w1 pos = true)
    (hCov2 : coversFile fid w2 pos = true)
    (hStrictTs : w1.modifiedTsNs < w2.modifiedTsNs) :
    resolveFileAt fid [w1, w2] pos = some (w2.modifiedTsNs, w2.val) ∧
    resolveFileAt fid [w2, w1] pos = some (w2.modifiedTsNs, w2.val) := by
  have hNotGt : ¬(w2.modifiedTsNs < w1.modifiedTsNs) := by omega
  constructor
  · dsimp [resolveFileAt, List.foldl]
    rw [hCov1, hCov2]
    dsimp [pickNewer]
    rw [if_pos hStrictTs]
  · dsimp [resolveFileAt, List.foldl]
    rw [hCov2, hCov1]
    dsimp [pickNewer]
    rw [if_neg hNotGt]

/-- THEOREM FM-05.3 (Out-of-Order Parallel Upload Swap Invariance): -/
theorem out_of_order_upload_swap_invariant
    (fid : Nat) (pre post : List ChunkWrite) (c1 c2 : ChunkWrite) (pos : Nat)
    (hNe : c1.modifiedTsNs ≠ c2.modifiedTsNs) :
    resolveFileAt fid (pre ++ c1 :: c2 :: post) pos =
    resolveFileAt fid (pre ++ c2 :: c1 :: post) pos := by
  unfold resolveFileAt
  simp only [List.foldl_append, List.foldl_cons]
  have hSwap : ∀ (acc : Option (Nat × Nat)),
      (if coversFile fid c2 pos then pickNewer (if coversFile fid c1 pos then pickNewer acc (some (c1.modifiedTsNs, c1.val)) else acc) (some (c2.modifiedTsNs, c2.val))
       else if coversFile fid c1 pos then pickNewer acc (some (c1.modifiedTsNs, c1.val)) else acc) =
      (if coversFile fid c1 pos then pickNewer (if coversFile fid c2 pos then pickNewer acc (some (c2.modifiedTsNs, c2.val)) else acc) (some (c1.modifiedTsNs, c1.val))
       else if coversFile fid c2 pos then pickNewer acc (some (c2.modifiedTsNs, c2.val)) else acc) := by
    intro acc
    cases hc1 : coversFile fid c1 pos <;> cases hc2 : coversFile fid c2 pos <;> simp
    exact pickNewer_assoc_distinct acc c1 c2 hNe
  rw [hSwap]

/-- THEOREM FM-05.4 (Cross-File Isolation): Chunks from `otherFid ≠ fid` have zero effect on `fid`. -/
theorem cross_file_isolation
    (fid : Nat) (pre post : List ChunkWrite) (other : ChunkWrite) (pos : Nat)
    (hOther : other.fileId ≠ fid) :
    resolveFileAt fid (pre ++ other :: post) pos = resolveFileAt fid (pre ++ post) pos := by
  unfold resolveFileAt
  simp only [List.foldl_append, List.foldl_cons]
  have hNoCov : coversFile fid other pos = false := by
    unfold coversFile
    apply decide_eq_false
    intro ⟨hF, _⟩
    exact hOther hF
  rw [hNoCov]
  simp

theorem resolve_foldl_eq_posix_foldl
    (fid : Nat) (cs : List ChunkWrite) (pos : Nat) (bound : Nat) (acc : Option (Nat × Nat))
    (hAcc : ∀ ts v, acc = some (ts, v) → ts ≤ bound)
    (hInc : StrictlyIncreasingTs bound cs) :
    cs.foldl (fun a c => if coversFile fid c pos then pickNewer a (some (c.modifiedTsNs, c.val)) else a) acc =
    cs.foldl (fun a c => if coversFile fid c pos then some (c.modifiedTsNs, c.val) else a) acc := by
  induction cs generalizing bound acc with
  | nil => rfl
  | cons c rest ih =>
      rcases hInc with ⟨hLt, hRestInc⟩
      dsimp [List.foldl]
      cases hCov : coversFile fid c pos
      · rw [if_neg (by decide), if_neg (by decide)]
        apply ih c.modifiedTsNs acc
        · intro ts v hEq; have := hAcc ts v hEq; omega
        · exact hRestInc
      · rw [if_pos rfl, if_pos rfl]
        have hPick : pickNewer acc (some (c.modifiedTsNs, c.val)) = some (c.modifiedTsNs, c.val) := by
          cases hA : acc with
          | none => rfl
          | some p =>
              rcases p with ⟨ts0, v0⟩
              have hLe := hAcc ts0 v0 hA
              dsimp [pickNewer]
              rw [if_pos (by omega)]
        rw [hPick]
        apply ih c.modifiedTsNs (some (c.modifiedTsNs, c.val))
        · intro ts v hEq; injection hEq with hP; injection hP with hT _; omega
        · exact hRestInc

/-- THEOREM FM-05.5 (Chunk Resolution Ordering Theorem — End-to-End Without Assumed Premises!):
    For ANY sequence of write requests `reqs` emitted through `FileSeqState` (with arbitrary
    wall-clock timestamps!), resolving the resulting chunks with `resolveFileAt` matches
    sequential POSIX evaluation `posixEvalFileAt` at EVERY byte offset `pos`! -/
theorem chunk_resolution_ordering_theorem
    (fid : Nat) (reqs : List WriteReq) (pos : Nat) :
    let emitted := (emitAll (initFileSeq fid) reqs).emitted
    resolveFileAt fid emitted pos = posixEvalFileAt fid emitted pos := by
  have hGen := generator_guarantees_seq_ts_equivalence fid reqs
  unfold resolveFileAt posixEvalFileAt
  exact resolve_foldl_eq_posix_foldl fid (emitAll (initFileSeq fid) reqs).emitted pos 0 none
    (by intro _ _ h; cases h) hGen.2.1

end FSALSeaweedFormal.ChunkOrdering
