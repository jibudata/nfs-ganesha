/-
  FM-01: C-Owned Native Arena Lifecycle — Tokenized Dual RefCount & Global Pool Isolation (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Addresses v0.3.3 Review P0 Findings for FM-01:
    1. Unique Ownership & Pin Tokens (`OwnerToken`, `PinToken`):
       - Replaces anonymous counters with explicit registered token sets (`ownerTokens`, `pinTokens`).
       - Proves double-drop / double-unpin are strict no-ops and one owner/worker can NEVER
         release another's token (`owner_token_isolation`, `worker_pin_token_isolation`).
    2. Complete Permanent ABA Immunity:
       - Covers ALL four stale-generation operations: `pinWorker`, `addOwner`, `dropOwner`, `unpinWorker`.
    3. Global `ArenaPool` Capacity, Priority & Allocation Isolation:
       - Models total finite capacity partitioned into `normalWrite` / `stableWriteReserve` / `readReserve`.
       - Proves `allocUnstablePool` never touches reserve pools, `allocStablePool` prefers `normalWrite`
         and falls back to `stableWriteReserve` (never touching `readReserve`, returning `none` when
         exhausted), `allocReadPool` never touches write pools, and sequential allocations NEVER alias
         a live physical `slotId`.
-/

namespace FSALSeaweedFormal.Arena

inductive PoolKind where
  | normalWrite        -- 80% capacity
  | stableWriteReserve -- 10% capacity (FILE_SYNC / DATA_SYNC immediate seal fallback)
  | readReserve        -- 10% capacity (Foreground READ only)
  deriving DecidableEq, Repr

inductive SlotState where
  | free
  | writableDirty
  | sealed
  | uploading
  | retryHolding
  | metadataCommitted
  | readActive
  | released
  deriving DecidableEq, Repr

/-- Value-only descriptor passed across the C/Go ABI (`struct sw_slot_ref`). -/
structure SlotRef where
  slotId     : Nat
  generation : Nat
  offset     : Nat
  length     : Nat
  deriving DecidableEq, Repr

/-- Unique long-lived ownership token (e.g., DirtyPageMap, UploadQueue, RetryQueue). -/
structure OwnerToken where
  tokenId    : Nat
  slotId     : Nat
  generation : Nat
  deriving DecidableEq, Repr

/-- Unique temporary read-pin token held by a specific Go worker. -/
structure PinToken where
  tokenId    : Nat
  slotId     : Nat
  generation : Nat
  workerId   : Nat
  deriving DecidableEq, Repr

structure ArenaSlot where
  slotId      : Nat
  pool        : PoolKind
  generation  : Nat
  ownerTokens : List OwnerToken
  pinTokens   : List PinToken
  nextTokenId : Nat
  state       : SlotState
  deriving DecidableEq, Repr

def ArenaSlot.ownerRefs (s : ArenaSlot) : Nat := s.ownerTokens.length
def ArenaSlot.activePins (s : ArenaSlot) : Nat := s.pinTokens.length

def hasOwner (ts : List OwnerToken) (tok : OwnerToken) : Bool :=
  match ts with
  | []      => false
  | t :: rs => if t = tok then true else hasOwner rs tok

def removeOwner (ts : List OwnerToken) (tok : OwnerToken) : List OwnerToken :=
  match ts with
  | []      => []
  | t :: rs => if t = tok then removeOwner rs tok else t :: removeOwner rs tok

def hasPin (ts : List PinToken) (tok : PinToken) : Bool :=
  match ts with
  | []      => false
  | t :: rs => if t = tok then true else hasPin rs tok

def removePin (ts : List PinToken) (tok : PinToken) : List PinToken :=
  match ts with
  | []      => []
  | t :: rs => if t = tok then removePin rs tok else t :: removePin rs tok

theorem hasOwner_iff_mem (ts : List OwnerToken) (tok : OwnerToken) :
    hasOwner ts tok = true ↔ tok ∈ ts := by
  induction ts with
  | nil => simp [hasOwner]
  | cons t rs ih =>
      dsimp [hasOwner]
      by_cases h : t = tok
      · subst h; simp
      · simp [h, ih]
        exact fun hEq => absurd hEq.symm h

theorem mem_removeOwner_iff (ts : List OwnerToken) (tok x : OwnerToken) :
    x ∈ removeOwner ts tok ↔ x ∈ ts ∧ x ≠ tok := by
  induction ts with
  | nil => simp [removeOwner]
  | cons t rs ih =>
      dsimp [removeOwner]
      by_cases h : t = tok
      · subst h
        rw [if_pos rfl, ih, List.mem_cons]
        constructor
        · intro ⟨hx, hNe⟩; exact ⟨Or.inr hx, hNe⟩
        · intro ⟨hm, hNe⟩
          rcases hm with rfl | hx
          · exact absurd rfl hNe
          · exact ⟨hx, hNe⟩
      · rw [if_neg h, List.mem_cons, List.mem_cons, ih]
        constructor
        · intro hm
          rcases hm with rfl | ⟨hx, hNe⟩
          · exact ⟨Or.inl rfl, h⟩
          · exact ⟨Or.inr hx, hNe⟩
        · intro ⟨hm, hNe⟩
          rcases hm with rfl | hx
          · exact Or.inl rfl
          · exact Or.inr ⟨hx, hNe⟩

theorem hasPin_iff_mem (ts : List PinToken) (tok : PinToken) :
    hasPin ts tok = true ↔ tok ∈ ts := by
  induction ts with
  | nil => simp [hasPin]
  | cons t rs ih =>
      dsimp [hasPin]
      by_cases h : t = tok
      · subst h; simp
      · simp [h, ih]
        exact fun hEq => absurd hEq.symm h

theorem mem_removePin_iff (ts : List PinToken) (tok x : PinToken) :
    x ∈ removePin ts tok ↔ x ∈ ts ∧ x ≠ tok := by
  induction ts with
  | nil => simp [removePin]
  | cons t rs ih =>
      dsimp [removePin]
      by_cases h : t = tok
      · subst h
        rw [if_pos rfl, ih, List.mem_cons]
        constructor
        · intro ⟨hx, hNe⟩; exact ⟨Or.inr hx, hNe⟩
        · intro ⟨hm, hNe⟩
          rcases hm with rfl | hx
          · exact absurd rfl hNe
          · exact ⟨hx, hNe⟩
      · rw [if_neg h, List.mem_cons, List.mem_cons, ih]
        constructor
        · intro hm
          rcases hm with rfl | ⟨hx, hNe⟩
          · exact ⟨Or.inl rfl, h⟩
          · exact ⟨Or.inr hx, hNe⟩
        · intro ⟨hm, hNe⟩
          rcases hm with rfl | hx
          · exact Or.inl rfl
          · exact Or.inr ⟨hx, hNe⟩

inductive ArenaEvent where
  | allocUnstable
  | allocStable
  | allocRead
  | addOwner     (ref : SlotRef)
  | dropOwner    (tok : OwnerToken)
  | pinWorker    (ref : SlotRef) (workerId : Nat)
  | unpinWorker  (tok : PinToken)
  | advancePhase (ref : SlotRef) (next : SlotState)
  deriving DecidableEq, Repr

/-- Recycle slot ONLY when BOTH `ownerTokens = []` AND `pinTokens = []`. -/
def maybeRecycle (s : ArenaSlot) : ArenaSlot :=
  if s.ownerTokens = [] ∧ s.pinTokens = [] ∧ s.state ≠ .free then
    { s with state := .free, generation := s.generation + 1 }
  else
    s

/-- Single-step state transition for an individual ArenaSlot with token verification. -/
def stepArena (s : ArenaSlot) (ev : ArenaEvent) : ArenaSlot :=
  match ev with
  | .allocUnstable =>
      if s.state = .free ∧ s.pool = .normalWrite then
        let tok : OwnerToken := { tokenId := s.nextTokenId, slotId := s.slotId, generation := s.generation }
        { s with
          state       := .writableDirty,
          ownerTokens := [tok],
          pinTokens   := [],
          nextTokenId := s.nextTokenId + 1 }
      else
        s
  | .allocStable =>
      if s.state = .free ∧ (s.pool = .normalWrite ∨ s.pool = .stableWriteReserve) then
        let tok : OwnerToken := { tokenId := s.nextTokenId, slotId := s.slotId, generation := s.generation }
        { s with
          state       := .writableDirty,
          ownerTokens := [tok],
          pinTokens   := [],
          nextTokenId := s.nextTokenId + 1 }
      else
        s
  | .allocRead =>
      if s.state = .free ∧ s.pool = .readReserve then
        let tok : OwnerToken := { tokenId := s.nextTokenId, slotId := s.slotId, generation := s.generation }
        { s with
          state       := .readActive,
          ownerTokens := [tok],
          pinTokens   := [],
          nextTokenId := s.nextTokenId + 1 }
      else
        s
  | .addOwner ref =>
      if s.slotId = ref.slotId ∧ s.generation = ref.generation ∧ s.state ≠ .free then
        let tok : OwnerToken := { tokenId := s.nextTokenId, slotId := s.slotId, generation := s.generation }
        { s with
          ownerTokens := tok :: s.ownerTokens,
          nextTokenId := s.nextTokenId + 1 }
      else
        s
  | .dropOwner tok =>
      if tok.slotId = s.slotId ∧ tok.generation = s.generation ∧ hasOwner s.ownerTokens tok = true then
        maybeRecycle { s with ownerTokens := removeOwner s.ownerTokens tok }
      else
        s
  | .pinWorker ref wid =>
      if s.slotId = ref.slotId ∧ s.generation = ref.generation ∧ s.state ≠ .free then
        let tok : PinToken := { tokenId := s.nextTokenId, slotId := s.slotId, generation := s.generation, workerId := wid }
        { s with
          pinTokens   := tok :: s.pinTokens,
          nextTokenId := s.nextTokenId + 1 }
      else
        s
  | .unpinWorker tok =>
      if tok.slotId = s.slotId ∧ tok.generation = s.generation ∧ hasPin s.pinTokens tok = true then
        maybeRecycle { s with pinTokens := removePin s.pinTokens tok }
      else
        s
  | .advancePhase ref next =>
      if s.slotId = ref.slotId ∧ s.generation = ref.generation ∧ s.state ≠ .free ∧ next ≠ .free then
        { s with state := next }
      else
        s

def runArena (s : ArenaSlot) (trace : List ArenaEvent) : ArenaSlot :=
  trace.foldl stepArena s

/-- Core Slot Structural Invariant:
    1. `state = .free ↔ (ownerTokens = [] ∧ pinTokens = [])`
    2. Every registered `OwnerToken` matches `(slotId, generation)` with `tokenId < nextTokenId`
    3. Every registered `PinToken` matches `(slotId, generation)` with `tokenId < nextTokenId` -/
def ArenaInv (s : ArenaSlot) : Prop :=
  (s.state = .free ↔ (s.ownerTokens = [] ∧ s.pinTokens = [])) ∧
  (∀ t, t ∈ s.ownerTokens → t.slotId = s.slotId ∧ t.generation = s.generation ∧ t.tokenId < s.nextTokenId) ∧
  (∀ t, t ∈ s.pinTokens → t.slotId = s.slotId ∧ t.generation = s.generation ∧ t.tokenId < s.nextTokenId)

theorem stepArena_preserves_inv (s : ArenaSlot) (ev : ArenaEvent) (hInv : ArenaInv s) :
    ArenaInv (stepArena s ev) := by
  rcases hInv with ⟨hFreeIff, hOwnValid, hPinValid⟩
  cases ev with
  | allocUnstable =>
      dsimp [stepArena]
      split
      · refine ⟨by simp, ?_, by simp⟩
        intro t ht
        simp at ht
        subst ht
        exact ⟨rfl, rfl, by dsimp only; omega⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | allocStable =>
      dsimp [stepArena]
      split
      · refine ⟨by simp, ?_, by simp⟩
        intro t ht
        simp at ht
        subst ht
        exact ⟨rfl, rfl, by dsimp only; omega⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | allocRead =>
      dsimp [stepArena]
      split
      · refine ⟨by simp, ?_, by simp⟩
        intro t ht
        simp at ht
        subst ht
        exact ⟨rfl, rfl, by dsimp only; omega⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | addOwner ref =>
      dsimp [stepArena]
      split
      · rename_i h
        refine ⟨⟨fun hf => absurd hf h.2.2, fun h0 => by simp at h0⟩, ?_, ?_⟩
        · intro t ht
          cases ht with
          | head => exact ⟨rfl, rfl, by dsimp only; omega⟩
          | tail _ hr =>
              have ⟨h1, h2, h3⟩ := hOwnValid t hr
              exact ⟨h1, h2, by dsimp only; omega⟩
        · intro t ht
          have ⟨h1, h2, h3⟩ := hPinValid t ht
          exact ⟨h1, h2, by dsimp only; omega⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | dropOwner tok =>
      dsimp [stepArena]
      split
      · rename_i h
        have hMem : tok ∈ s.ownerTokens := (hasOwner_iff_mem s.ownerTokens tok).mp h.2.2
        have hNotFree : s.state ≠ .free := by
          intro hF
          have ⟨hO, _⟩ := hFreeIff.mp hF
          rw [hO] at hMem
          cases hMem
        dsimp [maybeRecycle]
        split
        · rename_i hRec
          refine ⟨by simp [hRec.1, hRec.2.1], ?_, ?_⟩
          · intro t ht; rw [hRec.1] at ht; cases ht
          · intro t ht; rw [hRec.2.1] at ht; cases ht
        · rename_i hNotRec
          refine ⟨⟨fun hF => absurd hF hNotFree, fun ⟨hO, hP⟩ => absurd ⟨hO, hP, hNotFree⟩ hNotRec⟩, ?_, hPinValid⟩
          intro t ht
          have htOld := ((mem_removeOwner_iff s.ownerTokens tok t).mp ht).1
          exact hOwnValid t htOld
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | pinWorker ref wid =>
      dsimp [stepArena]
      split
      · rename_i h
        refine ⟨⟨fun hf => absurd hf h.2.2, fun h0 => by simp at h0⟩, ?_, ?_⟩
        · intro t ht
          have ⟨h1, h2, h3⟩ := hOwnValid t ht
          exact ⟨h1, h2, by dsimp only; omega⟩
        · intro t ht
          cases ht with
          | head => exact ⟨rfl, rfl, by dsimp only; omega⟩
          | tail _ hr =>
              have ⟨h1, h2, h3⟩ := hPinValid t hr
              exact ⟨h1, h2, by dsimp only; omega⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | unpinWorker tok =>
      dsimp [stepArena]
      split
      · rename_i h
        have hMem : tok ∈ s.pinTokens := (hasPin_iff_mem s.pinTokens tok).mp h.2.2
        have hNotFree : s.state ≠ .free := by
          intro hF
          have ⟨_, hP⟩ := hFreeIff.mp hF
          rw [hP] at hMem
          cases hMem
        dsimp [maybeRecycle]
        split
        · rename_i hRec
          refine ⟨by simp [hRec.1, hRec.2.1], ?_, ?_⟩
          · intro t ht; rw [hRec.1] at ht; cases ht
          · intro t ht; rw [hRec.2.1] at ht; cases ht
        · rename_i hNotRec
          refine ⟨⟨fun hF => absurd hF hNotFree, fun ⟨hO, hP⟩ => absurd ⟨hO, hP, hNotFree⟩ hNotRec⟩, hOwnValid, ?_⟩
          intro t ht
          have htOld := ((mem_removePin_iff s.pinTokens tok t).mp ht).1
          exact hPinValid t htOld
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩
  | advancePhase ref next =>
      dsimp [stepArena]
      split
      · rename_i h
        refine ⟨⟨fun hF => absurd hF h.2.2.2, fun h0 => absurd (hFreeIff.mpr h0) h.2.2.1⟩, hOwnValid, hPinValid⟩
      · exact ⟨hFreeIff, hOwnValid, hPinValid⟩

/-- THEOREM FM-01.1 (Inductive Trace Invariant): -/
theorem runArena_preserves_inv (s : ArenaSlot) (trace : List ArenaEvent) (hInv : ArenaInv s) :
    ArenaInv (runArena s trace) := by
  induction trace generalizing s with
  | nil => exact hInv
  | cons ev rest ih => exact ih (stepArena s ev) (stepArena_preserves_inv s ev hInv)

/-- THEOREM FM-01.2 (Global Invariant 1 — Zero UAF While Any Owner or Worker Token Exists): -/
theorem no_free_while_pinned_or_owned (s : ArenaSlot) (trace : List ArenaEvent) (hInv : ArenaInv s) :
    let s' := runArena s trace
    (s'.activePins > 0 ∨ s'.ownerRefs > 0) → s'.state ≠ .free := by
  intro s' hHeld hFree
  have hInv' := runArena_preserves_inv s trace hInv
  have ⟨hO, hP⟩ := hInv'.1.mp hFree
  dsimp [ArenaSlot.activePins, ArenaSlot.ownerRefs] at hHeld
  rw [hO, hP] at hHeld
  simp at hHeld

/-- THEOREM FM-01.3 (Owner Token Double-Drop Safety & Cross-Owner Isolation):
    1. Releasing `tok1` twice is a strict no-op on the second release.
    2. Releasing `tok1` NEVER removes another owner's `tok2` (`tok2 ≠ tok1`) and NEVER recycles the slot. -/
theorem owner_token_isolation
    (s : ArenaSlot) (tok1 tok2 : OwnerToken)
    (hInv : ArenaInv s) (hNe : tok2 ≠ tok1) (hIn2 : tok2 ∈ s.ownerTokens) :
    let s1 := stepArena s (.dropOwner tok1)
    tok1 ∉ s1.ownerTokens ∧
    stepArena s1 (.dropOwner tok1) = s1 ∧
    tok2 ∈ s1.ownerTokens ∧
    s1.state ≠ .free := by
  have hNotInAfter : tok1 ∉ (stepArena s (.dropOwner tok1)).ownerTokens := by
    dsimp [stepArena]
    split
    · dsimp [maybeRecycle]
      split
      · rename_i hRec; simp [hRec.1]
      · intro hMem
        have hBad := ((mem_removeOwner_iff s.ownerTokens tok1 tok1).mp hMem).2
        exact hBad rfl
    · rename_i hNot
      intro hMem
      have ⟨hSid, hGen, _⟩ := hInv.2.1 tok1 hMem
      exact hNot ⟨hSid, hGen, (hasOwner_iff_mem s.ownerTokens tok1).mpr hMem⟩
  have hIn2After : tok2 ∈ (stepArena s (.dropOwner tok1)).ownerTokens := by
    dsimp [stepArena]
    split
    · have hMemRem : tok2 ∈ removeOwner s.ownerTokens tok1 :=
        (mem_removeOwner_iff s.ownerTokens tok1 tok2).mpr ⟨hIn2, hNe⟩
      dsimp [maybeRecycle]
      split
      · rename_i hRec
        rw [hRec.1] at hMemRem
        cases hMemRem
      · exact hMemRem
    · exact hIn2
  have hDoubleNoop : stepArena (stepArena s (.dropOwner tok1)) (.dropOwner tok1) =
                     stepArena s (.dropOwner tok1) := by
    dsimp [stepArena]
    rw [if_neg]
    intro h
    exact hNotInAfter ((hasOwner_iff_mem _ tok1).mp h.2.2)
  have hNotFree : (stepArena s (.dropOwner tok1)).state ≠ .free := by
    have hInv1 := stepArena_preserves_inv s (.dropOwner tok1) hInv
    intro hF
    have ⟨hO, _⟩ := hInv1.1.mp hF
    rw [hO] at hIn2After
    cases hIn2After
  exact ⟨hNotInAfter, hDoubleNoop, hIn2After, hNotFree⟩

/-- THEOREM FM-01.4 (Worker PinToken Double-Unpin Safety & Cross-Worker Isolation):
    1. Unpinning `tok1` twice is a strict no-op on the second unpin.
    2. Worker 1 unpinning `tok1` NEVER removes Worker 2's `tok2` (`tok2 ≠ tok1`) and NEVER recycles the slot. -/
theorem worker_pin_token_isolation
    (s : ArenaSlot) (tok1 tok2 : PinToken)
    (hInv : ArenaInv s) (hNe : tok2 ≠ tok1) (hIn2 : tok2 ∈ s.pinTokens) :
    let s1 := stepArena s (.unpinWorker tok1)
    tok1 ∉ s1.pinTokens ∧
    stepArena s1 (.unpinWorker tok1) = s1 ∧
    tok2 ∈ s1.pinTokens ∧
    s1.state ≠ .free := by
  have hNotInAfter : tok1 ∉ (stepArena s (.unpinWorker tok1)).pinTokens := by
    dsimp [stepArena]
    split
    · dsimp [maybeRecycle]
      split
      · rename_i hRec; simp [hRec.2.1]
      · intro hMem
        have hBad := ((mem_removePin_iff s.pinTokens tok1 tok1).mp hMem).2
        exact hBad rfl
    · rename_i hNot
      intro hMem
      have ⟨hSid, hGen, _⟩ := hInv.2.2 tok1 hMem
      exact hNot ⟨hSid, hGen, (hasPin_iff_mem s.pinTokens tok1).mpr hMem⟩
  have hIn2After : tok2 ∈ (stepArena s (.unpinWorker tok1)).pinTokens := by
    dsimp [stepArena]
    split
    · have hMemRem : tok2 ∈ removePin s.pinTokens tok1 :=
        (mem_removePin_iff s.pinTokens tok1 tok2).mpr ⟨hIn2, hNe⟩
      dsimp [maybeRecycle]
      split
      · rename_i hRec
        rw [hRec.2.1] at hMemRem
        cases hMemRem
      · exact hMemRem
    · exact hIn2
  have hDoubleNoop : stepArena (stepArena s (.unpinWorker tok1)) (.unpinWorker tok1) =
                     stepArena s (.unpinWorker tok1) := by
    dsimp [stepArena]
    rw [if_neg]
    intro h
    exact hNotInAfter ((hasPin_iff_mem _ tok1).mp h.2.2)
  have hNotFree : (stepArena s (.unpinWorker tok1)).state ≠ .free := by
    have hInv1 := stepArena_preserves_inv s (.unpinWorker tok1) hInv
    intro hF
    have ⟨_, hP⟩ := hInv1.1.mp hF
    rw [hP] at hIn2After
    cases hIn2After
  exact ⟨hNotInAfter, hDoubleNoop, hIn2After, hNotFree⟩

/-- Generation monotonicity (single step & arbitrary trace). -/
theorem stepArena_generation_mono (s : ArenaSlot) (ev : ArenaEvent) :
    s.generation ≤ (stepArena s ev).generation := by
  cases ev <;> dsimp [stepArena]
  · split <;> simp
  · split <;> simp
  · split <;> simp
  · split <;> simp
  · split
    · dsimp [maybeRecycle]; split <;> (dsimp only; omega)
    · omega
  · split <;> simp
  · split
    · dsimp [maybeRecycle]; split <;> (dsimp only; omega)
    · omega
  · split <;> simp

theorem runArena_generation_mono (s : ArenaSlot) (trace : List ArenaEvent) :
    s.generation ≤ (runArena s trace).generation := by
  induction trace generalizing s with
  | nil => exact Nat.le_refl _
  | cons ev rest ih => exact Nat.le_trans (stepArena_generation_mono s ev) (ih (stepArena s ev))

/-- THEOREM FM-01.5 (Complete Permanent ABA Immunity Over ALL Future Traces):
    Covers ALL FOUR stale-generation operations (`pinWorker`, `addOwner`, `dropOwner`, `unpinWorker`)! -/
theorem permanent_aba_immunity
    (s : ArenaSlot) (ref : SlotRef) (oTok : OwnerToken) (pTok : PinToken) (wid : Nat)
    (future : List ArenaEvent)
    (hStaleRef : ref.generation < s.generation)
    (hStaleOwn : oTok.generation < s.generation)
    (hStalePin : pTok.generation < s.generation) :
    let s' := runArena s future
    stepArena s' (.pinWorker ref wid) = s' ∧
    stepArena s' (.addOwner ref) = s' ∧
    stepArena s' (.dropOwner oTok) = s' ∧
    stepArena s' (.unpinWorker pTok) = s' := by
  have hMono := runArena_generation_mono s future
  have hNeRef : ¬((runArena s future).generation = ref.generation) := by omega
  have hNeOwn : ¬(oTok.generation = (runArena s future).generation) := by omega
  have hNePin : ¬(pTok.generation = (runArena s future).generation) := by omega
  refine ⟨?_, ?_, ?_, ?_⟩
  · dsimp [stepArena]; rw [if_neg]; intro h; exact hNeRef h.2.1
  · dsimp [stepArena]; rw [if_neg]; intro h; exact hNeRef h.2.1
  · dsimp [stepArena]; rw [if_neg]; intro h; exact hNeOwn h.2.1
  · dsimp [stepArena]; rw [if_neg]; intro h; exact hNePin h.2.1

/- ============================================================================
   Global ArenaPool Model: Finite Capacity, Pool Isolation, Priority & Uniqueness
   ============================================================================ -/

structure ArenaPool where
  slots : List ArenaSlot
  deriving DecidableEq, Repr

def AllSlotIdsDistinct : List ArenaSlot → Prop
  | []      => True
  | s :: rs => (∀ r, r ∈ rs → r.slotId ≠ s.slotId) ∧ AllSlotIdsDistinct rs

def PoolInv (p : ArenaPool) : Prop :=
  AllSlotIdsDistinct p.slots ∧ (∀ s, s ∈ p.slots → ArenaInv s)

def countPoolKind (slots : List ArenaSlot) (k : PoolKind) : Nat :=
  match slots with
  | []      => 0
  | s :: rs => (if s.pool = k then 1 else 0) + countPoolKind rs k

/-- THEOREM FM-01.6 (Global Pool Capacity Partition Conservation): -/
theorem pool_capacity_partition (slots : List ArenaSlot) :
    slots.length = countPoolKind slots .normalWrite +
                   countPoolKind slots .stableWriteReserve +
                   countPoolKind slots .readReserve := by
  induction slots with
  | nil => rfl
  | cons s rs ih =>
      cases hP : s.pool <;> simp [countPoolKind, hP] <;> omega

/-- Find and allocate the first slot matching predicate `pred` via `ev`, leaving all other slots identical. -/
def allocFirstMatching (pred : ArenaSlot → Bool) (ev : ArenaEvent) :
    List ArenaSlot → List ArenaSlot × Option SlotRef
  | [] => ([], none)
  | s :: rs =>
      if pred s then
        let s' := stepArena s ev
        let ref : SlotRef := { slotId := s'.slotId, generation := s'.generation, offset := 0, length := 0 }
        (s' :: rs, some ref)
      else
        let (rs', res) := allocFirstMatching pred ev rs
        (s :: rs', res)

def isFreeIn (k : PoolKind) (s : ArenaSlot) : Bool :=
  decide (s.pool = k ∧ s.state = .free)

/-- Unstable write allocation: ONLY allocates from `.normalWrite`. Returns `none` (backpressure) if exhausted. -/
def allocUnstablePool (p : ArenaPool) : ArenaPool × Option SlotRef :=
  let (slots', res) := allocFirstMatching (isFreeIn .normalWrite) .allocUnstable p.slots
  ({ slots := slots' }, res)

/-- Stable write allocation: PREFERS `.normalWrite`; falls back to `.stableWriteReserve` ONLY when no
    `.normalWrite` slot is free; NEVER allocates from `.readReserve`; returns `none` when both exhausted. -/
def allocStablePool (p : ArenaPool) : ArenaPool × Option SlotRef :=
  let (slots1, res1) := allocFirstMatching (isFreeIn .normalWrite) .allocStable p.slots
  match res1 with
  | some ref => ({ slots := slots1 }, some ref)
  | none =>
      let (slots2, res2) := allocFirstMatching (isFreeIn .stableWriteReserve) .allocStable p.slots
      ({ slots := slots2 }, res2)

/-- Foreground read allocation: ONLY allocates from `.readReserve`. -/
def allocReadPool (p : ArenaPool) : ArenaPool × Option SlotRef :=
  let (slots', res) := allocFirstMatching (isFreeIn .readReserve) .allocRead p.slots
  ({ slots := slots' }, res)

theorem stepArena_preserves_slotId_and_pool (s : ArenaSlot) (ev : ArenaEvent) :
    (stepArena s ev).slotId = s.slotId ∧ (stepArena s ev).pool = s.pool := by
  cases ev <;> dsimp [stepArena]
  all_goals
    try (split <;> simp)
    try (split <;> (try dsimp [maybeRecycle]; try split) <;> simp)

theorem allocFirstMatching_preserves_slotIds_and_distinct
    (pred : ArenaSlot → Bool) (ev : ArenaEvent) (slots : List ArenaSlot)
    (hDist : AllSlotIdsDistinct slots) :
    let (slots', _) := allocFirstMatching pred ev slots
    AllSlotIdsDistinct slots' ∧
    (∀ s', s' ∈ slots' → ∃ s, s ∈ slots ∧ s'.slotId = s.slotId ∧ s'.pool = s.pool) := by
  induction slots with
  | nil =>
      simp [allocFirstMatching, AllSlotIdsDistinct]
  | cons s rs ih =>
      rcases hDist with ⟨hHeadNe, hRestDist⟩
      dsimp [allocFirstMatching]
      by_cases hp : pred s = true
      · rw [if_pos hp]
        dsimp [AllSlotIdsDistinct]
        have ⟨hId, hPool⟩ := stepArena_preserves_slotId_and_pool s ev
        refine ⟨⟨?_, hRestDist⟩, ?_⟩
        · intro r hr
          rw [hId]
          exact hHeadNe r hr
        · intro s' hs'
          cases hs' with
          | head => exact ⟨s, List.Mem.head _, hId, hPool⟩
          | tail _ hr => exact ⟨s', List.Mem.tail _ hr, rfl, rfl⟩
      · rw [if_neg hp]
        have ⟨hDist', hMap⟩ := ih hRestDist
        dsimp [AllSlotIdsDistinct]
        refine ⟨⟨?_, hDist'⟩, ?_⟩
        · intro r hr
          obtain ⟨old, hOldMem, hEqId, _⟩ := hMap r hr
          rw [hEqId]
          exact hHeadNe old hOldMem
        · intro s' hs'
          cases hs' with
          | head => exact ⟨s, List.Mem.head _, rfl, rfl⟩
          | tail _ hr =>
              obtain ⟨old, hOldMem, hEqId, hEqPool⟩ := hMap s' hr
              exact ⟨old, List.Mem.tail _ hOldMem, hEqId, hEqPool⟩

theorem allocFirstMatching_preserves_inv
    (pred : ArenaSlot → Bool) (ev : ArenaEvent) (slots : List ArenaSlot)
    (hAll : ∀ s, s ∈ slots → ArenaInv s) :
    ∀ s', s' ∈ (allocFirstMatching pred ev slots).1 → ArenaInv s' := by
  induction slots with
  | nil => simp [allocFirstMatching]
  | cons s rs ih =>
      dsimp [allocFirstMatching]
      by_cases hp : pred s = true
      · rw [if_pos hp]
        dsimp
        intro s' hs'
        cases hs' with
        | head => exact stepArena_preserves_inv s ev (hAll s (List.Mem.head _))
        | tail _ hr => exact hAll s' (List.Mem.tail _ hr)
      · rw [if_neg hp]
        dsimp
        intro s' hs'
        cases hs' with
        | head => exact hAll s (List.Mem.head _)
        | tail _ hr => exact ih (fun x hx => hAll x (List.Mem.tail _ hx)) s' hr

/-- Every slot NOT matching `pred` is preserved bit-for-bit identically in `allocFirstMatching`. -/
theorem allocFirstMatching_untouched_outside_pred
    (pred : ArenaSlot → Bool) (ev : ArenaEvent) (slots : List ArenaSlot)
    (k : PoolKind) (hDisj : ∀ s, s.pool = k → pred s = false) :
    ∀ s, s ∈ slots → s.pool = k → s ∈ (allocFirstMatching pred ev slots).1 := by
  induction slots with
  | nil => intro s hs; cases hs
  | cons x rs ih =>
      intro s hs hPool
      dsimp [allocFirstMatching]
      by_cases hp : pred x = true
      · rw [if_pos hp]
        dsimp
        cases hs with
        | head =>
            have hF := hDisj x hPool
            rw [hF] at hp
            cases hp
        | tail _ hr => exact List.Mem.tail _ hr
      · rw [if_neg hp]
        dsimp
        cases hs with
        | head => exact List.Mem.head _
        | tail _ hr => exact List.Mem.tail _ (ih s hr hPool)

/-- If NO slot satisfies `pred`, `allocFirstMatching` returns `(slots, none)`. -/
theorem allocFirstMatching_none_when_exhausted
    (pred : ArenaSlot → Bool) (ev : ArenaEvent) (slots : List ArenaSlot)
    (hNone : ∀ s, s ∈ slots → pred s = false) :
    allocFirstMatching pred ev slots = (slots, none) := by
  induction slots with
  | nil => rfl
  | cons x rs ih =>
      have hx := hNone x (List.Mem.head _)
      have hrs := ih (fun y hy => hNone y (List.Mem.tail _ hy))
      dsimp [allocFirstMatching]
      rw [hx]
      simp [hrs]

/-- If ANY slot satisfies `pred`, `allocFirstMatching` returns `some ref` where that slot is now non-free! -/
theorem allocFirstMatching_some_when_available
    (pred : ArenaSlot → Bool) (ev : ArenaEvent) (slots : List ArenaSlot)
    (target : ArenaSlot) (hIn : target ∈ slots) (hPred : pred target = true) :
    (allocFirstMatching pred ev slots).2.isSome = true := by
  induction slots with
  | nil => cases hIn
  | cons x rs ih =>
      dsimp [allocFirstMatching]
      by_cases hp : pred x = true
      · rw [if_pos hp]; rfl
      · rw [if_neg hp]
        dsimp
        cases hIn with
        | head => exact absurd hPred hp
        | tail _ hr => exact ih hr

/-- Any slot allocated by `allocFirstMatching (isFreeIn k) ev` is now in non-`.free` state with matching `slotId`! -/
theorem allocFirstMatching_result_becomes_nonfree
    (k : PoolKind) (ev : ArenaEvent) (slots : List ArenaSlot) (ref : SlotRef)
    (hNonFree : ∀ s, s.pool = k → s.state = .free → (stepArena s ev).state ≠ .free)
    (hRes : (allocFirstMatching (isFreeIn k) ev slots).2 = some ref) :
    ∃ s', s' ∈ (allocFirstMatching (isFreeIn k) ev slots).1 ∧
          s'.slotId = ref.slotId ∧ s'.pool = k ∧ s'.state ≠ .free := by
  induction slots with
  | nil => simp [allocFirstMatching] at hRes
  | cons x rs ih =>
      dsimp [allocFirstMatching] at hRes ⊢
      by_cases hp : isFreeIn k x = true
      · rw [if_pos hp] at hRes ⊢
        dsimp at hRes ⊢
        injection hRes with hRefEq
        have ⟨hPool, hFree⟩ : x.pool = k ∧ x.state = .free := by
          unfold isFreeIn at hp
          exact of_decide_eq_true hp
        have ⟨hId, hP⟩ := stepArena_preserves_slotId_and_pool x ev
        refine ⟨stepArena x ev, List.Mem.head _, ?_, ?_, hNonFree x hPool hFree⟩
        · rw [← hRefEq]
        · rw [hP, hPool]
      · rw [if_neg hp] at hRes ⊢
        dsimp at hRes ⊢
        obtain ⟨s', hs', hId, hP, hNF⟩ := ih hRes
        exact ⟨s', List.Mem.tail _ hs', hId, hP, hNF⟩

/-- THEOREM FM-01.7 (Global Pool Isolation — Unstable Write Never Touches Reserve Pools): -/
theorem allocUnstablePool_isolates_reserves (p : ArenaPool) (hInv : PoolInv p) :
    let (p', _) := allocUnstablePool p
    PoolInv p' ∧
    (∀ s, s ∈ p.slots → (s.pool = .stableWriteReserve ∨ s.pool = .readReserve) → s ∈ p'.slots) := by
  refine ⟨?_, ?_⟩
  · refine ⟨(allocFirstMatching_preserves_slotIds_and_distinct _ _ p.slots hInv.1).1,
            allocFirstMatching_preserves_inv _ _ p.slots hInv.2⟩
  · intro s hs hRes
    rcases hRes with hSR | hRR
    · exact allocFirstMatching_untouched_outside_pred (isFreeIn .normalWrite) .allocUnstable p.slots
        .stableWriteReserve (fun x hx => by simp [isFreeIn, hx]) s hs hSR
    · exact allocFirstMatching_untouched_outside_pred (isFreeIn .normalWrite) .allocUnstable p.slots
        .readReserve (fun x hx => by simp [isFreeIn, hx]) s hs hRR

/-- THEOREM FM-01.8 (Global Pool Policy — Stable Write Prefers Normal, Never Touches ReadReserve,
    and Returns `none` When Normal + StableReserve Are Both Exhausted): -/
theorem allocStablePool_policy (p : ArenaPool) (hInv : PoolInv p) :
    let (p', res) := allocStablePool p
    PoolInv p' ∧
    (∀ s, s ∈ p.slots → s.pool = .readReserve → s ∈ p'.slots) ∧
    ((∃ s, s ∈ p.slots ∧ s.pool = .normalWrite ∧ s.state = .free) →
      res.isSome = true ∧ ∀ s, s ∈ p.slots → s.pool = .stableWriteReserve → s ∈ p'.slots) ∧
    ((∀ s, s ∈ p.slots → (s.pool = .normalWrite ∨ s.pool = .stableWriteReserve) → s.state ≠ .free) →
      res = none ∧ p' = p) := by
  dsimp [allocStablePool]
  generalize hA1 : allocFirstMatching (isFreeIn .normalWrite) .allocStable p.slots = p1
  rcases p1 with ⟨slots1, res1⟩
  have hS1Eq : slots1 = (allocFirstMatching (isFreeIn .normalWrite) .allocStable p.slots).1 := by
    rw [hA1]
  have hR1Eq : res1 = (allocFirstMatching (isFreeIn .normalWrite) .allocStable p.slots).2 := by
    rw [hA1]
  cases res1 with
  | some ref =>
      dsimp
      refine ⟨⟨by rw [hS1Eq]; exact (allocFirstMatching_preserves_slotIds_and_distinct _ _ p.slots hInv.1).1,
               by rw [hS1Eq]; exact allocFirstMatching_preserves_inv _ _ p.slots hInv.2⟩,
              ?_, ?_, ?_⟩
      · intro s hs hRR
        rw [hS1Eq]
        exact allocFirstMatching_untouched_outside_pred (isFreeIn .normalWrite) .allocStable p.slots
          .readReserve (fun x hx => by simp [isFreeIn, hx]) s hs hRR
      · intro _
        refine ⟨rfl, ?_⟩
        intro s hs hSR
        rw [hS1Eq]
        exact allocFirstMatching_untouched_outside_pred (isFreeIn .normalWrite) .allocStable p.slots
          .stableWriteReserve (fun x hx => by simp [isFreeIn, hx]) s hs hSR
      · intro hExhaust
        have hNone := allocFirstMatching_none_when_exhausted (isFreeIn .normalWrite) .allocStable p.slots
          (fun x hx => by
            unfold isFreeIn
            apply decide_eq_false
            intro ⟨hP, hF⟩
            exact hExhaust x hx (Or.inl hP) hF)
        rw [hNone] at hR1Eq
        cases hR1Eq
  | none =>
      dsimp
      refine ⟨⟨(allocFirstMatching_preserves_slotIds_and_distinct _ _ p.slots hInv.1).1,
               allocFirstMatching_preserves_inv _ _ p.slots hInv.2⟩,
              ?_, ?_, ?_⟩
      · intro s hs hRR
        exact allocFirstMatching_untouched_outside_pred (isFreeIn .stableWriteReserve) .allocStable p.slots
          .readReserve (fun x hx => by simp [isFreeIn, hx]) s hs hRR
      · intro ⟨t, htIn, htPool, htFree⟩
        have hSome := allocFirstMatching_some_when_available (isFreeIn .normalWrite) .allocStable p.slots
          t htIn (by simp [isFreeIn, htPool, htFree])
        rw [← hR1Eq] at hSome
        cases hSome
      · intro hExhaust
        have hNone2 := allocFirstMatching_none_when_exhausted (isFreeIn .stableWriteReserve) .allocStable p.slots
          (fun x hx => by
            unfold isFreeIn
            apply decide_eq_false
            intro ⟨hP, hF⟩
            exact hExhaust x hx (Or.inr hP) hF)
        rw [hNone2]
        exact ⟨rfl, rfl⟩

/-- THEOREM FM-01.9 (Global Pool Isolation — Read Allocation Never Touches Write Pools): -/
theorem allocReadPool_isolates_writes (p : ArenaPool) (hInv : PoolInv p) :
    let (p', _) := allocReadPool p
    PoolInv p' ∧
    (∀ s, s ∈ p.slots → (s.pool = .normalWrite ∨ s.pool = .stableWriteReserve) → s ∈ p'.slots) := by
  refine ⟨⟨(allocFirstMatching_preserves_slotIds_and_distinct _ _ p.slots hInv.1).1,
           allocFirstMatching_preserves_inv _ _ p.slots hInv.2⟩, ?_⟩
  intro s hs hW
  rcases hW with hNW | hSR
  · exact allocFirstMatching_untouched_outside_pred (isFreeIn .readReserve) .allocRead p.slots
      .normalWrite (fun x hx => by simp [isFreeIn, hx]) s hs hNW
  · exact allocFirstMatching_untouched_outside_pred (isFreeIn .readReserve) .allocRead p.slots
      .stableWriteReserve (fun x hx => by simp [isFreeIn, hx]) s hs hSR

/-- Helper: under `AllSlotIdsDistinct`, no two members with the same `slotId` can differ in state. -/
theorem distinct_slotId_unique (slots : List ArenaSlot) (hDist : AllSlotIdsDistinct slots)
    (a b : ArenaSlot) (ha : a ∈ slots) (hb : b ∈ slots) (hId : a.slotId = b.slotId) :
    a = b := by
  induction slots with
  | nil => cases ha
  | cons x rs ih =>
      rcases hDist with ⟨hHeadNe, hRestDist⟩
      cases ha with
      | head =>
          cases hb with
          | head => rfl
          | tail _ hbr => exact absurd hId.symm (hHeadNe b hbr)
      | tail _ har =>
          cases hb with
          | head => exact absurd hId (hHeadNe a har)
          | tail _ hbr => exact ih hRestDist har hbr

/-- THEOREM FM-01.10 (No Double-Allocation / Physical Slot Mutual Exclusion):
    When two sequential allocations (`allocFirstMatching`) succeed from a valid `ArenaPool`,
    the second allocation NEVER returns the `slotId` of the first (still-live) allocated slot! -/
theorem sequential_alloc_no_duplicate_slotId
    (p : ArenaPool) (k1 k2 : PoolKind) (ev1 ev2 : ArenaEvent) (ref1 ref2 : SlotRef)
    (hInv : PoolInv p)
    (hNF1 : ∀ s, s.pool = k1 → s.state = .free → (stepArena s ev1).state ≠ .free)
    (hAlloc1 : (allocFirstMatching (isFreeIn k1) ev1 p.slots).2 = some ref1)
    (hAlloc2 : (allocFirstMatching (isFreeIn k2) ev2 (allocFirstMatching (isFreeIn k1) ev1 p.slots).1).2 = some ref2) :
    ref1.slotId ≠ ref2.slotId := by
  let slots1 := (allocFirstMatching (isFreeIn k1) ev1 p.slots).1
  have hDist1 : AllSlotIdsDistinct slots1 :=
    (allocFirstMatching_preserves_slotIds_and_distinct (isFreeIn k1) ev1 p.slots hInv.1).1
  obtain ⟨s1, hs1In, hs1Id, _, hs1NF⟩ :=
    allocFirstMatching_result_becomes_nonfree k1 ev1 p.slots ref1 hNF1 hAlloc1
  have hRef2WasFree : ∀ (ls : List ArenaSlot),
      (allocFirstMatching (isFreeIn k2) ev2 ls).2 = some ref2 →
      ∃ s2, s2 ∈ ls ∧ s2.slotId = ref2.slotId ∧ s2.state = .free := by
    intro ls
    induction ls with
    | nil => intro h; simp [allocFirstMatching] at h
    | cons x rs ih =>
        intro h
        dsimp [allocFirstMatching] at h
        by_cases hp : isFreeIn k2 x = true
        · rw [if_pos hp] at h
          dsimp at h
          injection h with hEq
          have ⟨_, hFree⟩ : x.pool = k2 ∧ x.state = .free := of_decide_eq_true hp
          have ⟨hIdX, _⟩ := stepArena_preserves_slotId_and_pool x ev2
          refine ⟨x, List.Mem.head _, ?_, hFree⟩
          rw [← hEq]; exact hIdX.symm
        · rw [if_neg hp] at h
          dsimp at h
          obtain ⟨s2, hs2In, hs2Id, hs2Free⟩ := ih h
          exact ⟨s2, List.Mem.tail _ hs2In, hs2Id, hs2Free⟩
  obtain ⟨s2, hs2In, hs2Id, hs2Free⟩ := hRef2WasFree slots1 hAlloc2
  intro hEq
  have hSameId : s1.slotId = s2.slotId := by omega
  have hSameSlot : s1 = s2 := distinct_slotId_unique slots1 hDist1 s1 s2 hs1In hs2In hSameId
  rw [hSameSlot] at hs1NF
  exact hs1NF hs2Free

end FSALSeaweedFormal.Arena
