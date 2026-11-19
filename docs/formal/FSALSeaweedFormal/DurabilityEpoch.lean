/-
  FM-04: Server-Wide NFS Write Verifier, Explicit COMMIT Responses & Symmetric Multi-Export Lifecycle (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Addresses ALL v0.3.3 Review P0 & P1 Findings for FM-04:
    1. P0 FIX (Explicit `CommitResult` Protocol Response):
       - Models `CommitResult := commitOk (verifier : Nat) | delay | ioError`.
       - Proves that `.inMemoryDirty`, `.uploading`, `.retryHolding`, AND `.volumeDurable`
         (Volume fsynced, Filer NOT yet committed!) ALL return `.delay` (`ERR_FSAL_DELAY`),
         NEVER `.commitOk`!
       - Proves that `.purgedLost` NEVER yields `appCommitted = true` and whenever `.commitOk v`
         is returned, `v ≠ clientWriteVerf` (forcing RFC 1813/8881 client dirty replay).
    2. P1 FIX (Full Symmetric Export A & Export B Lifecycles):
       - Parameterizes ALL lifecycle transitions (including `startUpload`, `transientFail`,
         `volumeFsyncOk`, `filerCommitOk`, `irrecoverableLoss`, `clientCommit`) symmetrically over
         `ExportId := expA | expB`, sharing a single process-global `serverEpoch`.
-/

namespace FSALSeaweedFormal.DurabilityEpoch

inductive ExportId where
  | expA
  | expB
  deriving DecidableEq, Repr

inductive DataState where
  | absent
  | inMemoryDirty
  | uploading
  | retryHolding      -- Transient upload error: C ArenaSlot RETAINED, serverEpoch NOT bumped
  | volumeDurable     -- Uploaded with ?fsync=true to Volume Server (Filer Entry NOT yet published)
  | metadataCommitted -- Volume durable AND Filer Entry committed (safe for COMMIT_OK)
  | purgedLost        -- Irrecoverable volatile loss / restart: global serverEpoch MUST advance
  deriving DecidableEq, Repr

inductive CommitResult where
  | commitOk (verifier : Nat)
  | delay
  | ioError
  deriving DecidableEq, Repr

structure ExportFileState where
  dataState       : DataState
  clientHasDirty  : Bool
  clientWriteVerf : Nat  -- Verifier returned to client by WRITE(UNSTABLE)
  appCommitted    : Bool -- True only once client receives COMMIT_OK with matching verifier
  lastCommitRes   : Option CommitResult
  deriving DecidableEq, Repr

/-- Process-global NFS server state with a single server-wide Write Verifier epoch shared by all Exports. -/
structure DurabilitySystem where
  serverEpoch : Nat -- Global g_server_durability_epoch shared across Export A & Export B
  expA        : ExportFileState
  expB        : ExportFileState
  deriving DecidableEq, Repr

/-- Fully symmetric event alphabet across Export A & Export B plus server-wide restart. -/
inductive DurabilityEvent where
  | acceptUnstableWrite (eid : ExportId)
  | startUpload         (eid : ExportId)
  | transientFail       (eid : ExportId)
  | volumeFsyncOk       (eid : ExportId)
  | filerCommitOk       (eid : ExportId)
  | irrecoverableLoss   (eid : ExportId) -- Purges volatile buffer on `eid` AND bumps global `serverEpoch`!
  | clientCommit        (eid : ExportId)
  | serverRestart                        -- Purges ALL volatile buffers AND bumps global `serverEpoch`!
  deriving DecidableEq, Repr

def purgeVolatile (f : ExportFileState) : ExportFileState :=
  match f.dataState with
  | .inMemoryDirty | .uploading | .retryHolding =>
      { f with dataState := .purgedLost }
  | _ => f

/-- Explicit NFS COMMIT execution returning `(nextState, CommitResult)`. -/
def applyCommit (f : ExportFileState) (globalEpoch : Nat) : ExportFileState × CommitResult :=
  if f.clientHasDirty = false then
    ({ f with lastCommitRes := some (.commitOk globalEpoch) }, .commitOk globalEpoch)
  else
    match f.dataState with
    | .metadataCommitted =>
        -- Both Volume (?fsync=true) and Filer Metadata are durable: return COMMIT_OK(globalEpoch).
        let res := CommitResult.commitOk globalEpoch
        if globalEpoch = f.clientWriteVerf then
          ({ f with clientHasDirty := false, appCommitted := true, lastCommitRes := some res }, res)
        else
          -- Verifier mismatch (e.g., sibling export bumped globalEpoch): client replays safely!
          ({ f with lastCommitRes := some res }, res)
    | .purgedLost =>
        -- Volatile data was lost and globalEpoch advanced: COMMIT_OK carries new globalEpoch ≠ clientWriteVerf!
        let res := CommitResult.commitOk globalEpoch
        if globalEpoch = f.clientWriteVerf then
          ({ f with clientHasDirty := false, appCommitted := true, lastCommitRes := some res }, res)
        else
          ({ f with lastCommitRes := some res }, res)
    | .absent =>
        ({ f with lastCommitRes := some .ioError }, .ioError)
    | .inMemoryDirty | .uploading | .retryHolding | .volumeDurable =>
        -- NOT durable on BOTH Volume + Filer yet: MUST return ERR_FSAL_DELAY (never COMMIT_OK!).
        ({ f with lastCommitRes := some .delay }, .delay)

def updateExport (st : DurabilitySystem) (eid : ExportId) (fn : ExportFileState → ExportFileState) :
    DurabilitySystem :=
  match eid with
  | .expA => { st with expA := fn st.expA }
  | .expB => { st with expB := fn st.expB }

def getExport (st : DurabilitySystem) (eid : ExportId) : ExportFileState :=
  match eid with
  | .expA => st.expA
  | .expB => st.expB

def stepDurability (st : DurabilitySystem) (ev : DurabilityEvent) : DurabilitySystem :=
  match ev with
  | .acceptUnstableWrite eid =>
      updateExport st eid (fun _ => {
        dataState       := .inMemoryDirty,
        clientHasDirty  := true,
        clientWriteVerf := st.serverEpoch,
        appCommitted    := false,
        lastCommitRes   := none })
  | .startUpload eid =>
      updateExport st eid (fun f =>
        if f.dataState = .inMemoryDirty then { f with dataState := .uploading } else f)
  | .transientFail eid =>
      updateExport st eid (fun f =>
        if f.dataState = .uploading then { f with dataState := .retryHolding } else f)
  | .volumeFsyncOk eid =>
      updateExport st eid (fun f =>
        if f.dataState = .uploading ∨ f.dataState = .retryHolding then
          { f with dataState := .volumeDurable }
        else f)
  | .filerCommitOk eid =>
      updateExport st eid (fun f =>
        if f.dataState = .volumeDurable then { f with dataState := .metadataCommitted } else f)
  | .irrecoverableLoss eid =>
      match (getExport st eid).dataState with
      | .inMemoryDirty | .uploading | .retryHolding =>
          let stPurged := updateExport st eid (fun f => { f with dataState := .purgedLost })
          { stPurged with serverEpoch := st.serverEpoch + 1 }
      | _ => st
  | .clientCommit eid =>
      updateExport st eid (fun f => (applyCommit f st.serverEpoch).1)
  | .serverRestart =>
      { serverEpoch := st.serverEpoch + 1,
        expA        := purgeVolatile st.expA,
        expB        := purgeVolatile st.expB }

def runDurability (st : DurabilitySystem) (trace : List DurabilityEvent) : DurabilitySystem :=
  trace.foldl stepDurability st

/-- Per-export durability invariant relative to the global `serverEpoch`. -/
def ExportInv (f : ExportFileState) (epoch : Nat) : Prop :=
  (f.clientWriteVerf ≤ epoch) ∧
  (f.dataState = .purgedLost → f.clientWriteVerf < epoch) ∧
  (f.appCommitted = true → f.dataState = .metadataCommitted)

def DurabilityInv (st : DurabilitySystem) : Prop :=
  ExportInv st.expA st.serverEpoch ∧ ExportInv st.expB st.serverEpoch

theorem exportInv_mono (f : ExportFileState) (ep : Nat) (h : ExportInv f ep) :
    ExportInv f (ep + 1) := by
  rcases h with ⟨hLe, hPurge, hApp⟩
  exact ⟨by omega, fun hp => by have := hPurge hp; omega, hApp⟩

theorem purgeVolatile_preserves_inv (f : ExportFileState) (ep : Nat) (h : ExportInv f ep) :
    ExportInv (purgeVolatile f) (ep + 1) := by
  rcases f with ⟨ds, dirty, verf, app, res⟩
  rcases h with ⟨hLe, hPurge, hApp⟩
  dsimp [purgeVolatile, ExportInv] at *
  cases ds <;> dsimp only
  · exact ⟨by omega, (fun hp => by cases hp), hApp⟩
  · exact ⟨by omega, (fun _ => by omega), (fun hA => by cases (hApp hA))⟩
  · exact ⟨by omega, (fun _ => by omega), (fun hA => by cases (hApp hA))⟩
  · exact ⟨by omega, (fun _ => by omega), (fun hA => by cases (hApp hA))⟩
  · exact ⟨by omega, (fun hp => by cases hp), hApp⟩
  · exact ⟨by omega, (fun hp => by cases hp), hApp⟩
  · exact ⟨by omega, (fun _ => by have := hPurge rfl; omega), hApp⟩

theorem applyCommit_preserves_inv (f : ExportFileState) (ep : Nat) (h : ExportInv f ep) :
    ExportInv (applyCommit f ep).1 ep := by
  rcases f with ⟨ds, dirty, verf, app, res⟩
  rcases h with ⟨hLe, hPurge, hApp⟩
  dsimp [applyCommit, ExportInv] at *
  by_cases hDirty : dirty = false
  · rw [if_pos hDirty]; exact ⟨hLe, hPurge, hApp⟩
  · rw [if_neg hDirty]
    cases ds <;> dsimp only
    · exact ⟨hLe, hPurge, hApp⟩
    · exact ⟨hLe, hPurge, hApp⟩
    · exact ⟨hLe, hPurge, hApp⟩
    · exact ⟨hLe, hPurge, hApp⟩
    · exact ⟨hLe, hPurge, hApp⟩
    · split
      · exact ⟨hLe, (fun hp => by cases hp), (fun _ => rfl)⟩
      · exact ⟨hLe, hPurge, hApp⟩
    · have hLt : verf < ep := hPurge rfl
      have hNe : ¬(ep = verf) := by omega
      rw [if_neg hNe]
      exact ⟨hLe, hPurge, hApp⟩

theorem stepDurability_preserves_inv (st : DurabilitySystem) (ev : DurabilityEvent)
    (hInv : DurabilityInv st) : DurabilityInv (stepDurability st ev) := by
  rcases hInv with ⟨hA, hB⟩
  cases ev with
  | acceptUnstableWrite eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · exact ⟨⟨Nat.le_refl _, (fun h => by cases h), (fun h => by cases h)⟩, hB⟩
      · exact ⟨hA, ⟨Nat.le_refl _, (fun h => by cases h), (fun h => by cases h)⟩⟩
  | startUpload eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · split
        · rename_i hD; rcases hA with ⟨hLe, _, hApp⟩
          exact ⟨⟨hLe, (fun h => by cases h), fun hC => by have := hApp hC; rw [hD] at this; cases this⟩, hB⟩
        · exact ⟨hA, hB⟩
      · split
        · rename_i hD; rcases hB with ⟨hLe, _, hApp⟩
          exact ⟨hA, ⟨hLe, (fun h => by cases h), fun hC => by have := hApp hC; rw [hD] at this; cases this⟩⟩
        · exact ⟨hA, hB⟩
  | transientFail eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · split
        · rename_i hD; rcases hA with ⟨hLe, _, hApp⟩
          exact ⟨⟨hLe, (fun h => by cases h), fun hC => by have := hApp hC; rw [hD] at this; cases this⟩, hB⟩
        · exact ⟨hA, hB⟩
      · split
        · rename_i hD; rcases hB with ⟨hLe, _, hApp⟩
          exact ⟨hA, ⟨hLe, (fun h => by cases h), fun hC => by have := hApp hC; rw [hD] at this; cases this⟩⟩
        · exact ⟨hA, hB⟩
  | volumeFsyncOk eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · split
        · rename_i hD; rcases hA with ⟨hLe, _, hApp⟩
          refine ⟨⟨hLe, (fun h => by cases h), ?_⟩, hB⟩
          intro hC; have hMeta := hApp hC
          rcases hD with h1 | h2
          · rw [hMeta] at h1; cases h1
          · rw [hMeta] at h2; cases h2
        · exact ⟨hA, hB⟩
      · split
        · rename_i hD; rcases hB with ⟨hLe, _, hApp⟩
          refine ⟨hA, ⟨hLe, (fun h => by cases h), ?_⟩⟩
          intro hC; have hMeta := hApp hC
          rcases hD with h1 | h2
          · rw [hMeta] at h1; cases h1
          · rw [hMeta] at h2; cases h2
        · exact ⟨hA, hB⟩
  | filerCommitOk eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · split
        · rcases hA with ⟨hLe, _, _⟩
          exact ⟨⟨hLe, (fun h => by cases h), fun _ => rfl⟩, hB⟩
        · exact ⟨hA, hB⟩
      · split
        · rcases hB with ⟨hLe, _, _⟩
          exact ⟨hA, ⟨hLe, (fun h => by cases h), fun _ => rfl⟩⟩
        · exact ⟨hA, hB⟩
  | irrecoverableLoss eid =>
      rcases st with ⟨ep, ⟨dsA, dirtyA, verfA, appA, resA⟩, ⟨dsB, dirtyB, verfB, appB, resB⟩⟩
      cases eid <;> dsimp [stepDurability, getExport, updateExport] at *
      · cases dsA <;> dsimp only
        · exact ⟨hA, hB⟩
        · rcases hA with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩,
                 exportInv_mono _ ep hB⟩
        · rcases hA with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩,
                 exportInv_mono _ ep hB⟩
        · rcases hA with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩,
                 exportInv_mono _ ep hB⟩
        · exact ⟨hA, hB⟩
        · exact ⟨hA, hB⟩
        · exact ⟨hA, hB⟩
      · cases dsB <;> dsimp only
        · exact ⟨hA, hB⟩
        · rcases hB with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨exportInv_mono _ ep hA,
                 ⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩⟩
        · rcases hB with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨exportInv_mono _ ep hA,
                 ⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩⟩
        · rcases hB with ⟨hLe, _, hApp⟩; dsimp only at hLe
          exact ⟨exportInv_mono _ ep hA,
                 ⟨by dsimp only; omega, (fun _ => by dsimp only; omega), (fun hC => by cases (hApp hC))⟩⟩
        · exact ⟨hA, hB⟩
        · exact ⟨hA, hB⟩
        · exact ⟨hA, hB⟩
  | clientCommit eid =>
      cases eid <;> dsimp [stepDurability, updateExport]
      · exact ⟨applyCommit_preserves_inv st.expA st.serverEpoch hA, hB⟩
      · exact ⟨hA, applyCommit_preserves_inv st.expB st.serverEpoch hB⟩
  | serverRestart =>
      exact ⟨purgeVolatile_preserves_inv st.expA st.serverEpoch hA,
             purgeVolatile_preserves_inv st.expB st.serverEpoch hB⟩

def initialSystem : DurabilitySystem :=
  { serverEpoch := 1,
    expA := { dataState := .absent, clientHasDirty := false, clientWriteVerf := 1,
              appCommitted := false, lastCommitRes := none },
    expB := { dataState := .absent, clientHasDirty := false, clientWriteVerf := 1,
              appCommitted := false, lastCommitRes := none } }

theorem initialSystem_inv : DurabilityInv initialSystem := by
  refine ⟨⟨Nat.le_refl _, (fun h => by cases h), (fun h => by cases h)⟩,
          ⟨Nat.le_refl _, (fun h => by cases h), (fun h => by cases h)⟩⟩

/-- THEOREM FM-04.1 (P0: Explicit COMMIT Response Semantics — Volume-Only or Volatile Data NEVER Returns `commitOk`):
    Whenever client has dirty data and the server is in `.inMemoryDirty`, `.uploading`, `.retryHolding`,
    OR `.volumeDurable` (Volume fsynced, Filer metadata NOT yet committed!), `applyCommit` returns `.delay`
    (`ERR_FSAL_DELAY`) and leaves `clientHasDirty = true`! -/
theorem incomplete_durability_commit_returns_delay
    (f : ExportFileState) (ep : Nat)
    (hDirty : f.clientHasDirty = true)
    (hNotMeta : f.dataState = .inMemoryDirty ∨ f.dataState = .uploading ∨
                f.dataState = .retryHolding ∨ f.dataState = .volumeDurable) :
    (applyCommit f ep).2 = .delay ∧ (applyCommit f ep).1.clientHasDirty = true := by
  dsimp [applyCommit]
  have hNe : f.clientHasDirty ≠ false := by rw [hDirty]; decide
  rw [if_neg hNe]
  rcases hNotMeta with h | h | h | h <;> simp [h, hDirty]

/-- THEOREM FM-04.2 (P0: Purged Loss COMMIT Always Exposes Verifier Mismatch & Prevents Silent Commit): -/
theorem purged_loss_commit_exposes_mismatch
    (f : ExportFileState) (ep : Nat)
    (hInv : ExportInv f ep) (hDirty : f.clientHasDirty = true) (hPurged : f.dataState = .purgedLost) :
    let (f', res) := applyCommit f ep
    res = .commitOk ep ∧
    ep ≠ f.clientWriteVerf ∧
    f'.clientHasDirty = true ∧
    f'.appCommitted = false := by
  have hLt : f.clientWriteVerf < ep := hInv.2.1 hPurged
  have hNeEp : ep ≠ f.clientWriteVerf := by omega
  have hAppFalse : f.appCommitted = false := by
    cases hA : f.appCommitted with
    | false => rfl
    | true => have := hInv.2.2 hA; rw [hPurged] at this; cases this
  dsimp [applyCommit]
  have hNeDirty : f.clientHasDirty ≠ false := by rw [hDirty]; decide
  rw [if_neg hNeDirty, hPurged]
  dsimp
  rw [if_neg hNeEp]
  exact ⟨rfl, hNeEp, hDirty, hAppFalse⟩

/-- THEOREM FM-04.3 (Global Invariant 2 — Zero Silent Data Loss Across ALL Symmetric Multi-Export Traces): -/
theorem zero_silent_data_loss_all_traces (trace : List DurabilityEvent) :
    let st := runDurability initialSystem trace
    (st.expA.appCommitted = true → st.expA.dataState = .metadataCommitted) ∧
    (st.expB.appCommitted = true → st.expB.dataState = .metadataCommitted) ∧
    (st.expA.dataState = .purgedLost → st.expA.clientWriteVerf < st.serverEpoch) ∧
    (st.expB.dataState = .purgedLost → st.expB.clientWriteVerf < st.serverEpoch) := by
  have hInd : ∀ s t, DurabilityInv s → DurabilityInv (runDurability s t) := by
    intro s t
    induction t generalizing s with
    | nil => intro h; exact h
    | cons ev rest ih => intro h; exact ih (stepDurability s ev) (stepDurability_preserves_inv s ev h)
  have hFinal := hInd initialSystem trace initialSystem_inv
  exact ⟨hFinal.1.2.2, hFinal.2.2.2, hFinal.1.2.1, hFinal.2.2.1⟩

end FSALSeaweedFormal.DurabilityEpoch
