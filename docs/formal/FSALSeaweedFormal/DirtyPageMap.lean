/-
  FM-02: C-Owned Dirty Page Map — Byte-Range Partial Overwrite, Physical Slot Distinctness
         & Safe In-Flight Sync/Upload Lifecycle (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Addresses ALL v0.3.3 Review P0 Findings for FM-02:
    - P0-1 FIX: `FILE_SYNC` NEVER overwrites an existing `inflightSlot`! When `inflightSlot.isSome`,
      a sync write returns `.backpressure` (no copy, no overwrite) instead of clobbering the
      in-flight reference. `write_never_mutates_inflight_slot` holds for BOTH async & sync writes!
    - P0-2 FIX: Enforces `distinctPhysicalSlot` (`a.slotId ≠ b.slotId`) so `writableSlot` and
      `inflightSlot` can NEVER alias the same physical C ArenaSlot.
    - P0-3 FIX: Replaces scalar `Nat` payload with byte-level mapping `PageBytes := Nat → Nat`
      and proves partial overwrite mutates ONLY `[offset, offset + length)` while leaving all
      outside bytes bit-for-bit preserved.
    - P0-4 FIX: Bijective 4-constructor `PageState` matching `(writableSlot, inflightSlot)`, plus
      explicit worker `PinToken` acquisition/release and outcome finalization gating `finishUpload`.
-/

import FSALSeaweedFormal.Arena

namespace FSALSeaweedFormal.DirtyPageMap

open FSALSeaweedFormal.Arena

def slotCapacity : Nat := 1048576 -- 1 MiB ArenaSlot

/-- Byte-level memory buffer model: byte offset `i` -> byte value `Nat`. -/
abbrev PageBytes := Nat → Nat

/-- Exact byte-range memcpy semantics into a page buffer:
    bytes inside `[off, off + len)` are copied from `payload (i - off)`;
    all bytes outside `[off, off + len)` remain untouched. -/
def applyByteWrite (old : PageBytes) (off len : Nat) (payload : PageBytes) : PageBytes :=
  fun i => if off ≤ i ∧ i < off + len then payload (i - off) else old i

/-- Physical slot non-aliasing predicate (P0-2). -/
def distinctPhysicalSlot (a b : ArenaSlot) : Prop :=
  a.slotId ≠ b.slotId

/-- Checks whether a physical `ArenaSlot` matches `SlotRef` identity `(slotId, generation)`. -/
def slotMatchesRef (s : ArenaSlot) (ref : SlotRef) : Prop :=
  s.slotId = ref.slotId ∧ s.generation = ref.generation

/-- Checks that `ref` matches `s` AND `s` is safe for in-place C memcpy (`writableDirty`, no pins). -/
def isWritableTarget (s : ArenaSlot) (ref : SlotRef) : Bool :=
  decide (s.slotId = ref.slotId ∧ s.generation = ref.generation ∧
          s.state = .writableDirty ∧ s.pinTokens = [])

inductive UploadOutcome where
  | succeeded
  | failedRetryable
  | failedFatal
  deriving DecidableEq, Repr

inductive WriteOutcome where
  | accepted
  | backpressure
  | rejectedInvalid
  deriving DecidableEq, Repr

/-- Exact 4-state configuration bijectively tracking `(inflightSlot, writableSlot)`:
    - `clean`:               inflight = none,   writable = none
    - `writableOnly`:        inflight = none,   writable = some ws
    - `inflightOnly`:        inflight = some i, writable = none
    - `inflightAndWritable`: inflight = some i, writable = some ws (COW coexistence!) -/
inductive PageState where
  | clean
  | writableOnly        (wRef : SlotRef)
  | inflightOnly        (iRef : SlotRef) (uploading : Bool)
  | inflightAndWritable (iRef : SlotRef) (uploading : Bool) (wRef : SlotRef)
  deriving DecidableEq, Repr

structure PageWrite where
  pageIdx : Nat
  offset  : Nat
  length  : Nat
  payload : PageBytes
  isSync  : Bool

def validWriteBounds (w : PageWrite) : Prop :=
  w.length > 0 ∧ w.offset + w.length ≤ slotCapacity

instance (w : PageWrite) : Decidable (validWriteBounds w) :=
  inferInstanceAs (Decidable (w.length > 0 ∧ w.offset + w.length ≤ slotCapacity))

structure PageMapSystem where
  pageState         : PageState
  writableSlot      : Option ArenaSlot
  inflightSlot      : Option ArenaSlot
  writableBytes     : PageBytes
  inflightBytes     : PageBytes
  uploadOutcome     : Option UploadOutcome
  lastWriteOutcome  : WriteOutcome
  acceptedWrites    : Nat
  realPayloadCopies : Nat

inductive PageOp where
  | writeOp         (w : PageWrite) (freshSlot : ArenaSlot)
  | sealWritable
  | workerPinUpload (workerId : Nat)
  | workerUnpinDone (tok : PinToken) (res : UploadOutcome)
  | finishUpload

def freshSlotDistinctFromInflight (st : PageMapSystem) (fresh : ArenaSlot) : Bool :=
  match st.inflightSlot with
  | none     => true
  | some inf => decide (fresh.slotId ≠ inf.slotId)

def stepPageMap (st : PageMapSystem) (op : PageOp) : PageMapSystem :=
  match op with
  | .writeOp w freshSlot =>
      if ¬validWriteBounds w then
        { st with lastWriteOutcome := .rejectedInvalid }
      else
        match st.pageState, st.writableSlot with
        -- Case 1A: Existing writable slot, NO active inflight slot
        | .writableOnly wRef, some ws =>
            if isWritableTarget ws wRef then
              let newBytes := applyByteWrite st.writableBytes w.offset w.length w.payload
              if w.isSync then
                -- Safe to immediately seal because `inflightSlot = none` (enforced by PageMapInv!)
                match st.inflightSlot with
                | none =>
                    { st with
                      pageState         := .inflightOnly wRef false,
                      writableSlot      := none,
                      inflightSlot      := some { ws with state := .sealed },
                      writableBytes     := newBytes,
                      inflightBytes     := newBytes,
                      uploadOutcome     := none,
                      lastWriteOutcome  := .accepted,
                      acceptedWrites    := st.acceptedWrites + 1,
                      realPayloadCopies := st.realPayloadCopies + 1 }
                | some _ =>
                    -- Defensive guard (unreachable under inv): never overwrite inflightSlot!
                    { st with lastWriteOutcome := .backpressure }
              else
                { st with
                  writableBytes     := newBytes,
                  lastWriteOutcome  := .accepted,
                  acceptedWrites    := st.acceptedWrites + 1,
                  realPayloadCopies := st.realPayloadCopies + 1 }
            else
              { st with lastWriteOutcome := .rejectedInvalid }

        -- Case 1B: Existing writable slot COEXISTING with an active inflight slot
        | .inflightAndWritable _iRef _up wRef, some ws =>
            if isWritableTarget ws wRef then
              if w.isSync then
                -- P0-1 FIX: inflightSlot is STILL ACTIVE! Do NOT overwrite it; return backpressure!
                { st with lastWriteOutcome := .backpressure }
              else
                -- Async partial overwrite mutates ONLY the physically distinct `writableSlot`!
                let newBytes := applyByteWrite st.writableBytes w.offset w.length w.payload
                { st with
                  writableBytes     := newBytes,
                  lastWriteOutcome  := .accepted,
                  acceptedWrites    := st.acceptedWrites + 1,
                  realPayloadCopies := st.realPayloadCopies + 1 }
            else
              { st with lastWriteOutcome := .rejectedInvalid }

        -- Case 2A: Clean page (no writable, no inflight) -> allocate fresh slot
        | .clean, none =>
            if freshSlot.state = .free ∧ freshSlot.ownerTokens = [] ∧ freshSlot.pinTokens = [] ∧
               freshSlotDistinctFromInflight st freshSlot = true ∧
               (w.isSync = true → (freshSlot.pool = .normalWrite ∨ freshSlot.pool = .stableWriteReserve)) ∧
               (w.isSync = false → freshSlot.pool = .normalWrite) then
              let tok : OwnerToken := {
                tokenId := freshSlot.nextTokenId, slotId := freshSlot.slotId, generation := freshSlot.generation
              }
              let allocated : ArenaSlot := {
                freshSlot with
                state       := .writableDirty,
                ownerTokens := [tok],
                pinTokens   := [],
                nextTokenId := freshSlot.nextTokenId + 1
              }
              let newRef : SlotRef := {
                slotId := freshSlot.slotId, generation := freshSlot.generation,
                offset := w.offset, length := w.length
              }
              let newBytes := applyByteWrite (fun _ => 0) w.offset w.length w.payload
              if w.isSync then
                match st.inflightSlot with
                | none =>
                    -- INV-RSV-DRAIN: FILE_SYNC immediately seals into inflightSlot (never parked in writable!)
                    { st with
                      pageState         := .inflightOnly newRef false,
                      writableSlot      := none,
                      inflightSlot      := some { allocated with state := .sealed },
                      writableBytes     := newBytes,
                      inflightBytes     := newBytes,
                      uploadOutcome     := none,
                      lastWriteOutcome  := .accepted,
                      acceptedWrites    := st.acceptedWrites + 1,
                      realPayloadCopies := st.realPayloadCopies + 1 }
                | some _ =>
                    { st with lastWriteOutcome := .backpressure }
              else
                { st with
                  pageState         := .writableOnly newRef,
                  writableSlot      := some allocated,
                  writableBytes     := newBytes,
                  lastWriteOutcome  := .accepted,
                  acceptedWrites    := st.acceptedWrites + 1,
                  realPayloadCopies := st.realPayloadCopies + 1 }
            else
              { st with lastWriteOutcome := .backpressure }

        -- Case 2B: Inflight-only page (old slot sealed or uploading) -> COW allocate physically distinct fresh slot
        | .inflightOnly iRef up, none =>
            if w.isSync then
              -- P0-1 FIX: Cannot immediately seal another slot while inflightSlot is still active!
              { st with lastWriteOutcome := .backpressure }
            else
              if freshSlot.state = .free ∧ freshSlot.ownerTokens = [] ∧ freshSlot.pinTokens = [] ∧
                 freshSlot.pool = .normalWrite ∧
                 freshSlotDistinctFromInflight st freshSlot = true then
                let tok : OwnerToken := {
                  tokenId := freshSlot.nextTokenId, slotId := freshSlot.slotId, generation := freshSlot.generation
                }
                let allocated : ArenaSlot := {
                  freshSlot with
                  state       := .writableDirty,
                  ownerTokens := [tok],
                  pinTokens   := [],
                  nextTokenId := freshSlot.nextTokenId + 1
                }
                let newRef : SlotRef := {
                  slotId := freshSlot.slotId, generation := freshSlot.generation,
                  offset := w.offset, length := w.length
                }
                let newBytes := applyByteWrite (fun _ => 0) w.offset w.length w.payload
                { st with
                  pageState         := .inflightAndWritable iRef up newRef,
                  writableSlot      := some allocated,
                  writableBytes     := newBytes,
                  lastWriteOutcome  := .accepted,
                  acceptedWrites    := st.acceptedWrites + 1,
                  realPayloadCopies := st.realPayloadCopies + 1 }
              else
                { st with lastWriteOutcome := .backpressure }

        | _, _ =>
            { st with lastWriteOutcome := .rejectedInvalid }

  | .sealWritable =>
      match st.pageState, st.writableSlot, st.inflightSlot with
      | .writableOnly wRef, some ws, none =>
          { st with
            pageState     := .inflightOnly wRef false,
            writableSlot  := none,
            inflightSlot  := some { ws with state := .sealed },
            inflightBytes := st.writableBytes,
            uploadOutcome := none }
      | _, _, _ => st

  | .workerPinUpload wid =>
      match st.pageState, st.inflightSlot with
      | .inflightOnly iRef false, some inf =>
          if inf.state = .sealed then
            let pinTok : PinToken := {
              tokenId := inf.nextTokenId, slotId := inf.slotId,
              generation := inf.generation, workerId := wid
            }
            { st with
              pageState     := .inflightOnly iRef true,
              inflightSlot  := some { inf with
                state       := .uploading,
                pinTokens   := pinTok :: inf.pinTokens,
                nextTokenId := inf.nextTokenId + 1 },
              uploadOutcome := none }
          else st
      | .inflightAndWritable iRef false wRef, some inf =>
          if inf.state = .sealed then
            let pinTok : PinToken := {
              tokenId := inf.nextTokenId, slotId := inf.slotId,
              generation := inf.generation, workerId := wid
            }
            { st with
              pageState     := .inflightAndWritable iRef true wRef,
              inflightSlot  := some { inf with
                state       := .uploading,
                pinTokens   := pinTok :: inf.pinTokens,
                nextTokenId := inf.nextTokenId + 1 },
              uploadOutcome := none }
          else st
      | _, _ => st

  | .workerUnpinDone tok res =>
      match st.inflightSlot with
      | some inf =>
          if inf.state = .uploading ∧ tok.slotId = inf.slotId ∧
             tok.generation = inf.generation ∧ hasPin inf.pinTokens tok = true then
            { st with
              inflightSlot  := some { inf with pinTokens := removePin inf.pinTokens tok },
              uploadOutcome := some res }
          else st
      | none => st

  | .finishUpload =>
      -- P0-4 FIX: finishUpload allowed ONLY when inflight is `.uploading`, ALL worker pins are released
      -- (`pinTokens = []`), AND `uploadOutcome` has been finalized!
      match st.pageState, st.inflightSlot, st.uploadOutcome with
      | .inflightOnly _ true, some inf, some _ =>
          if inf.state = .uploading ∧ inf.pinTokens = [] then
            { st with
              pageState     := .clean,
              inflightSlot  := none,
              uploadOutcome := none }
          else st
      | .inflightAndWritable _ true wRef, some inf, some _ =>
          if inf.state = .uploading ∧ inf.pinTokens = [] then
            { st with
              pageState     := .writableOnly wRef,
              inflightSlot  := none,
              uploadOutcome := none }
          else st
      | _, _, _ => st

def runPageMap (st : PageMapSystem) (ops : List PageOp) : PageMapSystem :=
  ops.foldl stepPageMap st

/-- Bijective consistency between `pageState` and `(writableSlot, inflightSlot)` (P0-4). -/
def PageStateConsistent (st : PageMapSystem) : Prop :=
  match st.pageState with
  | .clean =>
      st.writableSlot = none ∧ st.inflightSlot = none
  | .writableOnly wRef =>
      st.inflightSlot = none ∧
      ∃ ws, st.writableSlot = some ws ∧ slotMatchesRef ws wRef
  | .inflightOnly iRef up =>
      st.writableSlot = none ∧
      ∃ inf, st.inflightSlot = some inf ∧ slotMatchesRef inf iRef ∧
             inf.state = (if up then .uploading else .sealed)
  | .inflightAndWritable iRef up wRef =>
      (∃ inf, st.inflightSlot = some inf ∧ slotMatchesRef inf iRef ∧
              inf.state = (if up then .uploading else .sealed)) ∧
      (∃ ws, st.writableSlot = some ws ∧ slotMatchesRef ws wRef)

/-- Strengthened v0.3.4 PageMap Structural Invariant:
    1. Strictly 1 payload copy per accepted write (`realPayloadCopies = acceptedWrites`).
    2. `INV-RSV-DRAIN`: Every `writableSlot` is `.normalWrite`, `.writableDirty`, and `pinTokens = []`.
    3. Physical Slot Non-Aliasing (`P0-2`): `writableSlot` and `inflightSlot` NEVER share the same `slotId`.
    4. Exact Bijection (`P0-4`): `PageStateConsistent st`. -/
def PageMapInv (st : PageMapSystem) : Prop :=
  st.realPayloadCopies = st.acceptedWrites ∧
  (∀ ws, st.writableSlot = some ws → ws.pool = .normalWrite ∧ ws.state = .writableDirty ∧ ws.pinTokens = []) ∧
  (∀ ws inf, st.writableSlot = some ws → st.inflightSlot = some inf → distinctPhysicalSlot ws inf) ∧
  PageStateConsistent st

def initialPageMap : PageMapSystem :=
  { pageState         := .clean,
    writableSlot      := none,
    inflightSlot      := none,
    writableBytes     := fun _ => 0,
    inflightBytes     := fun _ => 0,
    uploadOutcome     := none,
    lastWriteOutcome  := .accepted,
    acceptedWrites    := 0,
    realPayloadCopies := 0 }

theorem initialPageMap_inv : PageMapInv initialPageMap := by
  refine ⟨rfl, ?_, ?_, ?_⟩
  · intro _ h; cases h
  · intro _ _ h _; cases h
  · exact ⟨rfl, rfl⟩

/-- THEOREM FM-02.1 (Byte-Range Partial Overwrite Exactness — P0-3):
    A partial overwrite on `[off, off + len)` leaves EVERY byte outside `[off, off + len)`
    bit-for-bit identical and updates EVERY byte inside `[off, off + len)` from `payload`. -/
theorem partial_overwrite_byte_semantics
    (old payload : PageBytes) (off len i : Nat) :
    ((i < off ∨ off + len ≤ i) → applyByteWrite old off len payload i = old i) ∧
    ((off ≤ i ∧ i < off + len) → applyByteWrite old off len payload i = payload (i - off)) := by
  constructor
  · intro hOut
    dsimp [applyByteWrite]
    rw [if_neg]
    omega
  · intro hIn
    dsimp [applyByteWrite]
    rw [if_pos hIn]

/-- THEOREM FM-02.2 (P0-1 & P0-3: Active `inflightSlot` Reference AND Byte Contents Are NEVER
    Overwritten or Mutated by ANY Write — Async OR `FILE_SYNC`!): -/
theorem write_never_overwrites_or_mutates_inflight
    (st : PageMapSystem) (w : PageWrite) (fresh : ArenaSlot) (inf : ArenaSlot)
    (hInv : PageMapInv st) (hInf : st.inflightSlot = some inf) :
    let st' := stepPageMap st (.writeOp w fresh)
    st'.inflightSlot = some inf ∧
    st'.inflightBytes = st.inflightBytes := by
  rcases hInv with ⟨_, _, _, hCons⟩
  dsimp [stepPageMap]
  by_cases hB : validWriteBounds w
  · rw [if_neg (fun hn => hn hB)]
    cases hPS : st.pageState with
    | clean =>
        rw [PageStateConsistent, hPS] at hCons
        rw [hCons.2] at hInf
        cases hInf
    | writableOnly wRef =>
        rw [PageStateConsistent, hPS] at hCons
        rw [hCons.1] at hInf
        cases hInf
    | inflightOnly iRef up =>
        rw [PageStateConsistent, hPS] at hCons
        rw [hCons.1]
        dsimp
        by_cases hSync : w.isSync = true
        · rw [if_pos hSync]; exact ⟨hInf, rfl⟩
        · rw [if_neg hSync]
          split <;> exact ⟨hInf, rfl⟩
    | inflightAndWritable iRef up wRef =>
        rw [PageStateConsistent, hPS] at hCons
        obtain ⟨_, ⟨ws, hWs, _⟩⟩ := hCons
        rw [hWs]
        dsimp
        by_cases hWT : isWritableTarget ws wRef = true
        · rw [if_pos hWT]
          by_cases hSync : w.isSync = true
          · rw [if_pos hSync]; exact ⟨hInf, rfl⟩
          · rw [if_neg hSync]; exact ⟨hInf, rfl⟩
        · rw [if_neg hWT]; exact ⟨hInf, rfl⟩
  · rw [if_pos hB]; exact ⟨hInf, rfl⟩

/-- Helper: inductive step preserves all 4 clauses of `PageMapInv`. -/
theorem stepPageMap_preserves_inv (st : PageMapSystem) (op : PageOp) (hInv : PageMapInv st) :
    PageMapInv (stepPageMap st op) := by
  have hInvOrig : PageMapInv st := hInv
  rcases hInv with ⟨hCopy, hWsInv, hDist, hCons⟩
  cases op with
  | writeOp w fresh =>
      dsimp [stepPageMap]
      by_cases hB : validWriteBounds w
      · rw [if_neg (fun hn => hn hB)]
        cases hPS : st.pageState with
        | clean =>
            rw [PageStateConsistent, hPS] at hCons
            rcases hCons with ⟨hWNone, hINone⟩
            rw [hWNone]
            dsimp
            split
            · rename_i hGuard
              by_cases hSync : w.isSync = true
              · rw [if_pos hSync, hINone]
                dsimp
                refine ⟨by dsimp only; omega, ?_, ?_, ?_⟩
                · intro _ h; cases h
                · intro _ _ h _; cases h
                · dsimp [PageStateConsistent]
                  exact ⟨rfl, _, rfl, ⟨rfl, rfl⟩, rfl⟩
              · rw [if_neg hSync]
                have hSyncF : w.isSync = false := by cases hS : w.isSync <;> simp_all
                have hNorm : fresh.pool = .normalWrite := hGuard.2.2.2.2.2 hSyncF
                refine ⟨by dsimp only; omega, ?_, ?_, ?_⟩
                · intro ws hEq; injection hEq with h; subst h; exact ⟨hNorm, rfl, rfl⟩
                · intro _ _ _ hInf; rw [hINone] at hInf; cases hInf
                · dsimp [PageStateConsistent]
                  exact ⟨hINone, _, rfl, ⟨rfl, rfl⟩⟩
            · rw [← hPS, ← hWNone]; exact hInvOrig
        | writableOnly wRef =>
            rw [PageStateConsistent, hPS] at hCons
            rcases hCons with ⟨hINone, ⟨ws, hWsEq, hMatch⟩⟩
            rw [hWsEq]
            dsimp
            by_cases hWT : isWritableTarget ws wRef = true
            · rw [if_pos hWT]
              by_cases hSync : w.isSync = true
              · rw [if_pos hSync, hINone]
                dsimp
                refine ⟨by dsimp only; omega, ?_, ?_, ?_⟩
                · intro _ h; cases h
                · intro _ _ h _; cases h
                · dsimp [PageStateConsistent]
                  exact ⟨rfl, _, rfl, hMatch, rfl⟩
              · rw [if_neg hSync]
                refine ⟨by dsimp only; omega,
                        (fun ws' h => hWsInv ws' (by rw [hWsEq]; exact h)),
                        (fun ws' inf' h1 h2 => hDist ws' inf' (by rw [hWsEq]; exact h1) h2), ?_⟩
                dsimp [PageStateConsistent]
                exact ⟨hINone, ws, rfl, hMatch⟩
            · rw [if_neg hWT]
              rw [← hPS, ← hWsEq]; exact hInvOrig
        | inflightOnly iRef up =>
            rw [PageStateConsistent, hPS] at hCons
            rcases hCons with ⟨hWNone, ⟨inf, hInfEq, hInfMatch, hInfState⟩⟩
            rw [hWNone]
            dsimp
            by_cases hSync : w.isSync = true
            · rw [if_pos hSync]
              rw [← hPS, ← hWNone]; exact hInvOrig
            · rw [if_neg hSync]
              split
              · rename_i hGuard
                have hNeId : fresh.slotId ≠ inf.slotId := by
                  have hF := hGuard.2.2.2.2
                  unfold freshSlotDistinctFromInflight at hF
                  rw [hInfEq] at hF
                  exact of_decide_eq_true hF
                refine ⟨by dsimp only; omega, ?_, ?_, ?_⟩
                · intro ws hEq; injection hEq with h; subst h; exact ⟨hGuard.2.2.2.1, rfl, rfl⟩
                · intro ws inf' hWs' hInf'
                  injection hWs' with hW; subst hW
                  rw [hInfEq] at hInf'; injection hInf' with hI; subst hI
                  exact hNeId
                · dsimp [PageStateConsistent]
                  exact ⟨⟨inf, hInfEq, hInfMatch, hInfState⟩, ⟨_, rfl, ⟨rfl, rfl⟩⟩⟩
              · rw [← hPS, ← hWNone]; exact hInvOrig
        | inflightAndWritable iRef up wRef =>
            rw [PageStateConsistent, hPS] at hCons
            rcases hCons with ⟨⟨inf, hInfEq, hInfMatch, hInfState⟩, ⟨ws, hWsEq, hWsMatch⟩⟩
            rw [hWsEq]
            dsimp
            by_cases hWT : isWritableTarget ws wRef = true
            · rw [if_pos hWT]
              by_cases hSync : w.isSync = true
              · rw [if_pos hSync]
                rw [← hPS, ← hWsEq]; exact hInvOrig
              · rw [if_neg hSync]
                refine ⟨by dsimp only; omega,
                        (fun ws' h => hWsInv ws' (by rw [hWsEq]; exact h)),
                        (fun ws' inf' h1 h2 => hDist ws' inf' (by rw [hWsEq]; exact h1) h2), ?_⟩
                dsimp [PageStateConsistent]
                exact ⟨⟨inf, hInfEq, hInfMatch, hInfState⟩, ⟨ws, rfl, hWsMatch⟩⟩
            · rw [if_neg hWT]
              rw [← hPS, ← hWsEq]; exact hInvOrig
      · rw [if_pos hB]
        exact ⟨hCopy, hWsInv, hDist, hCons⟩

  | sealWritable =>
      dsimp [stepPageMap]
      cases hPS : st.pageState with
      | writableOnly wRef =>
          rw [PageStateConsistent, hPS] at hCons
          rcases hCons with ⟨hINone, ⟨ws, hWsEq, hMatch⟩⟩
          rw [hWsEq, hINone]
          dsimp
          refine ⟨hCopy, ?_, ?_, ?_⟩
          · intro _ h; cases h
          · intro _ _ h _; cases h
          · dsimp [PageStateConsistent]; exact ⟨rfl, _, rfl, hMatch, rfl⟩
      | clean => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | inflightOnly _ _ => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | inflightAndWritable _ _ _ => exact ⟨hCopy, hWsInv, hDist, hCons⟩

  | workerPinUpload wid =>
      dsimp [stepPageMap]
      cases hPS : st.pageState with
      | inflightOnly iRef up =>
          cases up with
          | false =>
              rw [PageStateConsistent, hPS] at hCons
              rcases hCons with ⟨hWNone, ⟨inf, hInfEq, hInfMatch, hInfState⟩⟩
              rw [hInfEq]
              dsimp at hInfState ⊢
              rw [if_pos hInfState]
              refine ⟨hCopy, hWsInv, ?_, ?_⟩
              · intro ws _ hWs _; rw [hWNone] at hWs; cases hWs
              · dsimp [PageStateConsistent]
                exact ⟨hWNone, _, rfl, hInfMatch, rfl⟩
          | true => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | inflightAndWritable iRef up wRef =>
          cases up with
          | false =>
              rw [PageStateConsistent, hPS] at hCons
              rcases hCons with ⟨⟨inf, hInfEq, hInfMatch, hInfState⟩, ⟨ws, hWsEq, hWsMatch⟩⟩
              rw [hInfEq]
              dsimp at hInfState ⊢
              rw [if_pos hInfState]
              refine ⟨hCopy, hWsInv, ?_, ?_⟩
              · intro ws' inf' hW' hI'
                injection hI' with hIEq; subst hIEq
                exact hDist ws' inf hW' hInfEq
              · dsimp [PageStateConsistent]
                exact ⟨⟨_, rfl, hInfMatch, rfl⟩, ⟨ws, hWsEq, hWsMatch⟩⟩
          | true => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | clean => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | writableOnly _ => exact ⟨hCopy, hWsInv, hDist, hCons⟩

  | workerUnpinDone tok res =>
      dsimp [stepPageMap]
      cases hInfEq : st.inflightSlot with
      | none => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | some inf =>
          dsimp
          split
          · rename_i hCond
            refine ⟨hCopy, hWsInv, ?_, ?_⟩
            · intro ws' inf' hW' hI'
              injection hI' with hIEq; subst hIEq
              exact hDist ws' inf hW' hInfEq
            · dsimp [PageStateConsistent] at hCons ⊢
              cases hPS : st.pageState with
              | clean => rw [hPS] at hCons; rw [hCons.2] at hInfEq; cases hInfEq
              | writableOnly _ => rw [hPS] at hCons; rw [hCons.1] at hInfEq; cases hInfEq
              | inflightOnly iRef up =>
                  rw [hPS] at hCons
                  rcases hCons with ⟨hWNone, ⟨inf0, hInf0, hM, hS⟩⟩
                  rw [hInfEq] at hInf0; injection hInf0 with hEq; subst hEq
                  exact ⟨hWNone, _, rfl, hM, hS⟩
              | inflightAndWritable iRef up wRef =>
                  rw [hPS] at hCons
                  rcases hCons with ⟨⟨inf0, hInf0, hM, hS⟩, hWPart⟩
                  rw [hInfEq] at hInf0; injection hInf0 with hEq; subst hEq
                  exact ⟨⟨_, rfl, hM, hS⟩, hWPart⟩
          · exact ⟨hCopy, hWsInv, hDist, hCons⟩

  | finishUpload =>
      dsimp [stepPageMap]
      cases hPS : st.pageState with
      | inflightOnly iRef up =>
          cases up with
          | true =>
              cases hInfEq : st.inflightSlot with
              | none => exact ⟨hCopy, hWsInv, hDist, hCons⟩
              | some inf =>
                  cases hRes : st.uploadOutcome with
                  | none => exact ⟨hCopy, hWsInv, hDist, hCons⟩
                  | some out =>
                      dsimp
                      split
                      · rw [PageStateConsistent, hPS] at hCons
                        refine ⟨hCopy, hWsInv, ?_, ?_⟩
                        · intro _ _ _ h; cases h
                        · dsimp [PageStateConsistent]; exact ⟨hCons.1, rfl⟩
                      · exact ⟨hCopy, hWsInv, hDist, hCons⟩
          | false => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | inflightAndWritable iRef up wRef =>
          cases up with
          | true =>
              cases hInfEq : st.inflightSlot with
              | none => exact ⟨hCopy, hWsInv, hDist, hCons⟩
              | some inf =>
                  cases hRes : st.uploadOutcome with
                  | none => exact ⟨hCopy, hWsInv, hDist, hCons⟩
                  | some out =>
                      dsimp
                      split
                      · rw [PageStateConsistent, hPS] at hCons
                        refine ⟨hCopy, hWsInv, ?_, ?_⟩
                        · intro _ _ _ h; cases h
                        · dsimp [PageStateConsistent]; exact ⟨rfl, hCons.2⟩
                      · exact ⟨hCopy, hWsInv, hDist, hCons⟩
          | false => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | clean => exact ⟨hCopy, hWsInv, hDist, hCons⟩
      | writableOnly _ => exact ⟨hCopy, hWsInv, hDist, hCons⟩

/-- THEOREM FM-02.3 (Inductive Trace Invariant: Single-Copy + INV-RSV-DRAIN +
    Physical Slot Non-Aliasing + Exact PageState/Slot Bijection Over ALL Traces): -/
theorem runPageMap_preserves_all_invariants
    (ops : List PageOp) :
    PageMapInv (runPageMap initialPageMap ops) := by
  have hInd : ∀ st xs, PageMapInv st → PageMapInv (runPageMap st xs) := by
    intro st xs
    induction xs generalizing st with
    | nil => intro h; exact h
    | cons op rest ih => intro h; exact ih (stepPageMap st op) (stepPageMap_preserves_inv st op h)
  exact hInd initialPageMap ops initialPageMap_inv

/-- THEOREM FM-02.4 (Physical Slot Non-Aliasing Corollary — P0-2):
    Across ALL reachable traces, whenever `writableSlot` and `inflightSlot` coexist,
    they are GUARANTEED to have distinct physical `slotId`s (`ws.slotId ≠ inf.slotId`). -/
theorem writable_and_inflight_physically_distinct
    (ops : List PageOp) (ws inf : ArenaSlot)
    (hW : (runPageMap initialPageMap ops).writableSlot = some ws)
    (hI : (runPageMap initialPageMap ops).inflightSlot = some inf) :
    distinctPhysicalSlot ws inf :=
  (runPageMap_preserves_all_invariants ops).2.2.1 ws inf hW hI

/-- THEOREM FM-02.5 (Safe `finishUpload` Precondition — P0-4):
    If `inflightSlot` still has an active worker pin (`pinTokens ≠ []`) OR `uploadOutcome = none`,
    `finishUpload` is a strict no-op and NEVER drops `inflightSlot`! -/
theorem finishUpload_blocked_while_pinned_or_undetermined
    (st : PageMapSystem) (inf : ArenaSlot)
    (hInf : st.inflightSlot = some inf)
    (hBlocked : inf.pinTokens ≠ [] ∨ st.uploadOutcome = none) :
    stepPageMap st .finishUpload = st := by
  dsimp [stepPageMap]
  cases st.pageState with
  | clean => rfl
  | writableOnly _ => rfl
  | inflightOnly _ up =>
      cases up with
      | false => rfl
      | true =>
          rw [hInf]
          cases hOut : st.uploadOutcome with
          | none => rfl
          | some _ =>
              dsimp
              rw [if_neg]
              intro ⟨_, hEmpty⟩
              rcases hBlocked with hNe | hNone
              · exact hNe hEmpty
              · rw [hOut] at hNone; cases hNone
  | inflightAndWritable _ up _ =>
      cases up with
      | false => rfl
      | true =>
          rw [hInf]
          cases hOut : st.uploadOutcome with
          | none => rfl
          | some _ =>
              dsimp
              rw [if_neg]
              intro ⟨_, hEmpty⟩
              rcases hBlocked with hNe | hNone
              · exact hNe hEmpty
              · rw [hOut] at hNone; cases hNone

end FSALSeaweedFormal.DirtyPageMap
