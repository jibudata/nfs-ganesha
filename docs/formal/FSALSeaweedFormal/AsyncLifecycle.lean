/-
  FM-03: Decoupled Asynchronous Request Completion & Tokenized Worker Pin Lifecycle (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Addresses ALL v0.3.3 Review P0 & P1 Findings for FM-03:
    1. P0 FIX (Worker Identity & PinToken Pairing):
       - Reuses `OwnerToken` and `PinToken` (with `workerId` & unique `tokenId`) from FM-01.
       - Every worker acquires its own `PinToken` on `workerStartRead wid`, and releases ONLY its
         own `PinToken` on `workerNormalFinish tok` or `workerPanicOrCancel tok`.
       - Proves one worker's duplicate finish NEVER unpins another worker (`worker_pin_isolation_in_async`).
    2. P1 FIX (Explicit 3-State `submitted → completing → completed` + Initial Condition):
       - Explicitly models CAS ownership of `.completing` (`completer : Option CompleterId`).
       - Proves that while `.completing`, neither Watchdog nor any other worker can re-enter or
         trigger a duplicate callback (`completing_blocks_watchdog_and_duplicates`).
       - Explicitly models callback failure (`cbOk : Bool`) still completing cleanup without re-entry.
       - Defines canonical `initAsyncState` and proves `initAsyncState_inv : AsyncInv initAsyncState`.
-/

import FSALSeaweedFormal.Arena

namespace FSALSeaweedFormal.AsyncLifecycle

open FSALSeaweedFormal.Arena

inductive ReqCompletionState where
  | submitted
  | completing
  | completed
  deriving DecidableEq, Repr

inductive CompleterId where
  | worker   (workerId : Nat)
  | watchdog
  deriving DecidableEq, Repr

structure AsyncSystemState where
  slotId       : Nat
  generation   : Nat
  nextTokenId  : Nat
  reqState     : ReqCompletionState
  completer    : Option CompleterId -- Unique CAS winner of `submitted -> completing`
  doneCbCount  : Nat
  reqCleanedUp : Bool
  ownerTokens  : List OwnerToken
  pinTokens    : List PinToken
  recycled     : Bool
  deriving DecidableEq, Repr

inductive AsyncEvent where
  | workerStartRead     (workerId : Nat)                   -- Worker pins slot -> mints PinToken
  | workerNormalFinish  (tok : PinToken)                   -- Worker unpins its PinToken & attempts CAS
  | workerPanicOrCancel (tok : PinToken)                   -- Panic/cancel unwind unpins its PinToken & attempts CAS
  | watchdogBeginTimeout                                   -- Watchdog attempts CAS ONLY (NEVER touches pins!)
  | execCallbackFinish  (actor : CompleterId) (cbOk : Bool)-- CAS winner runs Ganesha done_cb & cleans up req
  | dropOwnerToken      (tok : OwnerToken)                 -- Owner drops its registered OwnerToken
  | duplicateLateNotify (actor : CompleterId)              -- Spurious/duplicate late notification
  deriving DecidableEq, Repr

def maybeRecycle (st : AsyncSystemState) : AsyncSystemState :=
  if st.ownerTokens = [] ∧ st.pinTokens = [] ∧ st.recycled = false then
    { st with recycled := true, generation := st.generation + 1 }
  else
    st

/-- Step 1 of completion: Atomic CAS `submitted -> completing`, recording the unique winner `actor`. -/
def casBeginComplete (st : AsyncSystemState) (actor : CompleterId) : AsyncSystemState :=
  if st.reqState = .submitted then
    { st with reqState := .completing, completer := some actor }
  else
    st

def stepAsync (st : AsyncSystemState) (ev : AsyncEvent) : AsyncSystemState :=
  match ev with
  | .workerStartRead wid =>
      if st.recycled = false ∧ st.ownerTokens ≠ [] then
        let tok : PinToken := {
          tokenId := st.nextTokenId, slotId := st.slotId,
          generation := st.generation, workerId := wid
        }
        { st with
          pinTokens   := tok :: st.pinTokens,
          nextTokenId := st.nextTokenId + 1 }
      else
        st
  | .workerNormalFinish tok =>
      if tok.slotId = st.slotId ∧ tok.generation = st.generation ∧ hasPin st.pinTokens tok = true then
        let stUnpinned := maybeRecycle { st with pinTokens := removePin st.pinTokens tok }
        casBeginComplete stUnpinned (.worker tok.workerId)
      else
        st
  | .workerPanicOrCancel tok =>
      if tok.slotId = st.slotId ∧ tok.generation = st.generation ∧ hasPin st.pinTokens tok = true then
        let stUnpinned := maybeRecycle { st with pinTokens := removePin st.pinTokens tok }
        casBeginComplete stUnpinned (.worker tok.workerId)
      else
        st
  | .watchdogBeginTimeout =>
      -- Watchdog ONLY attempts CAS `submitted -> completing` — NEVER touches `pinTokens` or `recycled`!
      casBeginComplete st .watchdog
  | .execCallbackFinish actor _cbOk =>
      -- Step 2 of completion: ONLY the unique CAS winner in `.completing` executes `done_cb` and cleans up.
      -- Even if `_cbOk = false`, request transitions cleanly to `.completed` with cleanup done (never re-run).
      if st.reqState = .completing ∧ st.completer = some actor then
        { st with
          reqState     := .completed,
          doneCbCount  := st.doneCbCount + 1,
          reqCleanedUp := true }
      else
        st
  | .dropOwnerToken tok =>
      if tok.slotId = st.slotId ∧ tok.generation = st.generation ∧ hasOwner st.ownerTokens tok = true then
        maybeRecycle { st with ownerTokens := removeOwner st.ownerTokens tok }
      else
        st
  | .duplicateLateNotify actor =>
      casBeginComplete st actor

def runAsync (st : AsyncSystemState) (trace : List AsyncEvent) : AsyncSystemState :=
  trace.foldl stepAsync st

/-- Canonical initial state for a submitted async request owning 1 ArenaSlot token. -/
def initAsyncState (slotId gen : Nat) : AsyncSystemState :=
  let initOwner : OwnerToken := { tokenId := 0, slotId := slotId, generation := gen }
  { slotId       := slotId,
    generation   := gen,
    nextTokenId  := 1,
    reqState     := .submitted,
    completer    := none,
    doneCbCount  := 0,
    reqCleanedUp := false,
    ownerTokens  := [initOwner],
    pinTokens    := [],
    recycled     := false }

/-- Combined Inductive Safety Invariant across both decoupled state machines. -/
def AsyncInv (st : AsyncSystemState) : Prop :=
  (st.reqState = .submitted  → st.doneCbCount = 0 ∧ st.completer = none ∧ st.reqCleanedUp = false) ∧
  (st.reqState = .completing → st.doneCbCount = 0 ∧ st.completer.isSome = true) ∧
  (st.reqState = .completed  → st.doneCbCount = 1 ∧ st.reqCleanedUp = true) ∧
  (st.doneCbCount ≤ 1) ∧
  (st.recycled = true → st.ownerTokens = [] ∧ st.pinTokens = []) ∧
  (∀ t, t ∈ st.ownerTokens → t.slotId = st.slotId ∧ t.generation = st.generation ∧ t.tokenId < st.nextTokenId) ∧
  (∀ t, t ∈ st.pinTokens   → t.slotId = st.slotId ∧ t.generation = st.generation ∧ t.tokenId < st.nextTokenId)

theorem initAsyncState_inv (slotId gen : Nat) : AsyncInv (initAsyncState slotId gen) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro _; exact ⟨rfl, rfl, rfl⟩
  · intro h; cases h
  · intro h; cases h
  · dsimp [initAsyncState]; omega
  · intro h; cases h
  · intro t ht
    simp [initAsyncState] at ht
    subst ht
    exact ⟨rfl, rfl, by dsimp [initAsyncState]; omega⟩
  · intro t ht; simp [initAsyncState] at ht

theorem casBeginComplete_preserves_inv (st : AsyncSystemState) (actor : CompleterId)
    (hInv : AsyncInv st) : AsyncInv (casBeginComplete st actor) := by
  rcases hInv with ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  dsimp [casBeginComplete]
  split
  · rename_i hS
    have ⟨hZero, _, _⟩ := hSub hS
    refine ⟨(by intro h; cases h), (by intro _; exact ⟨hZero, rfl⟩), (by intro h; cases h), hLe, hRec, hOwn, hPin⟩
  · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩

theorem maybeRecycle_preserves_inv (st : AsyncSystemState) (hInv : AsyncInv st) :
    AsyncInv (maybeRecycle st) := by
  rcases hInv with ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  dsimp [maybeRecycle]
  split
  · rename_i hR
    refine ⟨hSub, hComp, hDone, hLe, by intro _; exact ⟨hR.1, hR.2.1⟩, ?_, ?_⟩
    · intro t ht; rw [hR.1] at ht; cases ht
    · intro t ht; rw [hR.2.1] at ht; cases ht
  · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩

theorem stepAsync_preserves_inv (st : AsyncSystemState) (ev : AsyncEvent) (hInv : AsyncInv st) :
    AsyncInv (stepAsync st ev) := by
  rcases hInv with ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  cases ev with
  | workerStartRead wid =>
      dsimp [stepAsync]
      split
      · rename_i hG
        refine ⟨hSub, hComp, hDone, hLe, ?_, ?_, ?_⟩
        · intro hT; rw [hG.1] at hT; cases hT
        · intro t ht
          have ⟨h1, h2, h3⟩ := hOwn t ht
          exact ⟨h1, h2, by dsimp only; omega⟩
        · intro t ht
          cases ht with
          | head => exact ⟨rfl, rfl, by dsimp only; omega⟩
          | tail _ hr =>
              have ⟨h1, h2, h3⟩ := hPin t hr
              exact ⟨h1, h2, by dsimp only; omega⟩
      · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | workerNormalFinish tok =>
      dsimp [stepAsync]
      split
      · rename_i hG
        apply casBeginComplete_preserves_inv
        apply maybeRecycle_preserves_inv
        refine ⟨hSub, hComp, hDone, hLe, ?_, hOwn, ?_⟩
        · intro hT
          have hMem := (hasPin_iff_mem st.pinTokens tok).mp hG.2.2
          have ⟨_, hP0⟩ := hRec hT
          rw [hP0] at hMem; cases hMem
        · intro t ht
          exact hPin t ((mem_removePin_iff st.pinTokens tok t).mp ht).1
      · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | workerPanicOrCancel tok =>
      dsimp [stepAsync]
      split
      · rename_i hG
        apply casBeginComplete_preserves_inv
        apply maybeRecycle_preserves_inv
        refine ⟨hSub, hComp, hDone, hLe, ?_, hOwn, ?_⟩
        · intro hT
          have hMem := (hasPin_iff_mem st.pinTokens tok).mp hG.2.2
          have ⟨_, hP0⟩ := hRec hT
          rw [hP0] at hMem; cases hMem
        · intro t ht
          exact hPin t ((mem_removePin_iff st.pinTokens tok t).mp ht).1
      · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | watchdogBeginTimeout =>
      exact casBeginComplete_preserves_inv st .watchdog ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | execCallbackFinish actor cbOk =>
      dsimp [stepAsync]
      split
      · rename_i hG
        have ⟨hZero, _⟩ := hComp hG.1
        refine ⟨(by intro h; cases h), (by intro h; cases h), (by intro _; exact ⟨by dsimp only; omega, rfl⟩),
                (by dsimp only; omega), hRec, hOwn, hPin⟩
      · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | dropOwnerToken tok =>
      dsimp [stepAsync]
      split
      · rename_i hG
        apply maybeRecycle_preserves_inv
        refine ⟨hSub, hComp, hDone, hLe, ?_, ?_, hPin⟩
        · intro hT
          have hMem := (hasOwner_iff_mem st.ownerTokens tok).mp hG.2.2
          have ⟨hO0, _⟩ := hRec hT
          rw [hO0] at hMem; cases hMem
        · intro t ht
          exact hOwn t ((mem_removeOwner_iff st.ownerTokens tok t).mp ht).1
      · exact ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩
  | duplicateLateNotify actor =>
      exact casBeginComplete_preserves_inv st actor ⟨hSub, hComp, hDone, hLe, hRec, hOwn, hPin⟩

theorem runAsync_preserves_inv (st : AsyncSystemState) (trace : List AsyncEvent) (hInv : AsyncInv st) :
    AsyncInv (runAsync st trace) := by
  induction trace generalizing st with
  | nil => exact hInv
  | cons ev rest ih => exact ih (stepAsync st ev) (stepAsync_preserves_inv st ev hInv)

/-- THEOREM FM-03.1 (Callback At-Most-Once & Clean Completion Across ALL Traces): -/
theorem callback_at_most_once
    (slotId gen : Nat) (trace : List AsyncEvent) :
    let final := runAsync (initAsyncState slotId gen) trace
    final.doneCbCount ≤ 1 ∧
    (final.reqState = .completed → final.doneCbCount = 1 ∧ final.reqCleanedUp = true) := by
  have hInv := runAsync_preserves_inv (initAsyncState slotId gen) trace (initAsyncState_inv slotId gen)
  exact ⟨hInv.2.2.2.1, hInv.2.2.1⟩

/-- THEOREM FM-03.2 (`.completing` Exclusivity — Watchdog & Non-Winner Actors Blocked):
    Once an actor wins `submitted -> completing`, neither Watchdog nor any other actor's
    `duplicateLateNotify` or `execCallbackFinish` can steal completion or invoke `done_cb`! -/
theorem completing_blocks_watchdog_and_non_winners
    (st : AsyncSystemState) (winner other : CompleterId) (cbOk : Bool)
    (hComp : st.reqState = .completing)
    (hWin : st.completer = some winner)
    (hNe : other ≠ winner) :
    stepAsync st .watchdogBeginTimeout = st ∧
    stepAsync st (.duplicateLateNotify other) = st ∧
    stepAsync st (.execCallbackFinish other cbOk) = st := by
  refine ⟨?_, ?_, ?_⟩
  · dsimp [stepAsync, casBeginComplete]; rw [if_neg]; intro h; rw [hComp] at h; cases h
  · dsimp [stepAsync, casBeginComplete]; rw [if_neg]; intro h; rw [hComp] at h; cases h
  · dsimp [stepAsync]; rw [if_neg]; intro ⟨_, hEq⟩; rw [hWin] at hEq; injection hEq with h; exact hNe h.symm

/-- THEOREM FM-03.3 (Worker PinToken Isolation in Async Lifecycle — P0):
    Worker 1 completing or panicking with `tok1` NEVER releases Worker 2's `tok2` (`tok2 ≠ tok1`)
    and NEVER recycles the ArenaSlot while Worker 2 is still reading! -/
theorem worker_pin_isolation_in_async
    (st : AsyncSystemState) (tok1 tok2 : PinToken)
    (hInv : AsyncInv st) (hNe : tok2 ≠ tok1) (hIn2 : tok2 ∈ st.pinTokens) :
    let stN := stepAsync st (.workerNormalFinish tok1)
    let stP := stepAsync st (.workerPanicOrCancel tok1)
    (tok2 ∈ stN.pinTokens ∧ stN.recycled = false) ∧
    (tok2 ∈ stP.pinTokens ∧ stP.recycled = false) := by
  have hHelper : ∀ (ev : AsyncEvent), (ev = .workerNormalFinish tok1 ∨ ev = .workerPanicOrCancel tok1) →
      tok2 ∈ (stepAsync st ev).pinTokens ∧ (stepAsync st ev).recycled = false := by
    intro ev hEv
    have hStepInv := stepAsync_preserves_inv st ev hInv
    have hInAfter : tok2 ∈ (stepAsync st ev).pinTokens := by
      rcases hEv with rfl | rfl <;> (
        dsimp [stepAsync]
        split
        · have hRem : tok2 ∈ removePin st.pinTokens tok1 :=
            (mem_removePin_iff st.pinTokens tok1 tok2).mpr ⟨hIn2, hNe⟩
          dsimp [casBeginComplete]
          split
          · dsimp only [maybeRecycle]; split <;> exact hRem
          · dsimp only [maybeRecycle]; split <;> exact hRem
        · exact hIn2
      )
    have hNotRec : (stepAsync st ev).recycled = false := by
      cases hR : (stepAsync st ev).recycled with
      | false => rfl
      | true =>
          have ⟨_, hP0⟩ := hStepInv.2.2.2.2.1 hR
          rw [hP0] at hInAfter
          cases hInAfter
    exact ⟨hInAfter, hNotRec⟩
  exact ⟨hHelper _ (Or.inl rfl), hHelper _ (Or.inr rfl)⟩

/-- THEOREM FM-03.4 (Zero UAF — No Recycle While Any Worker PinToken or OwnerToken Exists): -/
theorem no_recycle_while_pinned_or_owned
    (slotId gen : Nat) (trace : List AsyncEvent) :
    let final := runAsync (initAsyncState slotId gen) trace
    (final.pinTokens ≠ [] ∨ final.ownerTokens ≠ []) → final.recycled = false := by
  intro final hHeld
  have hRec := (runAsync_preserves_inv (initAsyncState slotId gen) trace (initAsyncState_inv slotId gen)).2.2.2.2.1
  cases hR : final.recycled with
  | false => rfl
  | true =>
      have ⟨hO, hP⟩ := hRec hR
      rcases hHeld with h1 | h2
      · exact absurd hP h1
      · exact absurd hO h2

end FSALSeaweedFormal.AsyncLifecycle
