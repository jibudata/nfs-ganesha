/-
  FM-06: Immutable SeaweedObjectID, Multi-Path HardLinks & Open-Unlink Lifecycle (v0.3.4)
  Target Baselines:
    - NFS-Ganesha: dev-V15.9 (42bc41b62c12346aea30357cb613944e1032890b)
    - SeaweedFS:   dev-4.48  (530be3e37337488ecc34d58441e0bc476e121c93)

  Addresses ALL v0.3.3 Review P1 Findings for FM-06:
    - Strengthens `ObjInv` to enforce SIX simultaneous lifecycle invariants across ALL traces:
        1. `INV-OBJECTID-IMMUTABLE`: `objectId = birthId` permanently.
        2. `INV-HARDLINK-SAME-OBJECT`: Every active path resolves to `birthId`.
        3. `PathIdsUnique`: No duplicate directory entries for the same pathId.
        4. `INV-NLINK-CONSISTENT`: `paths.length = obj.nlink` at ALL states!
        5. `INV-OPEN-UNLINK`: `openRefs > 0 → reclaimed = false`.
        6. `INV-RECLAIMED-CLEAN`: `reclaimed = true → nlink = 0 ∧ openRefs = 0 ∧ paths = []`!
-/

namespace FSALSeaweedFormal.ObjectIdentity

structure FileObject where
  objectId   : Nat        -- 128-bit UUID in Entry.Extended["nfs.object_id"] (IMMUTABLE)
  hardLinkId : Option Nat -- SeaweedFS Filer HardLinkId (NEVER replaces objectId!)
  nlink      : Nat        -- Number of active directory entries pointing to this object
  openRefs   : Nat        -- Active NFSv4 Open States (SAL state_t count)
  isOrphan   : Bool       -- True when unlinked while openRefs > 0
  reclaimed  : Bool       -- True only once final DeleteEntry + chunk GC ran
  deriving DecidableEq, Repr

structure NamespaceObjectState where
  obj   : FileObject
  paths : List (Nat × Nat) -- Active `(pathId, resolvedObjectId)` directory entries
  deriving DecidableEq, Repr

inductive ObjEvent where
  | createHardLink   (newPathId : Nat) (filerHlId : Nat)
  | unlinkPath       (pathId : Nat)
  | openObject
  | closeObject
  | graceOrphanSweep (graceEnded : Bool)
  deriving DecidableEq, Repr

def hasPath (ps : List (Nat × Nat)) (target : Nat) : Bool :=
  match ps with
  | []           => false
  | (p, _) :: rs => if p = target then true else hasPath rs target

def removePath (ps : List (Nat × Nat)) (target : Nat) : List (Nat × Nat) :=
  match ps with
  | []           => []
  | (p, o) :: rs => if p = target then removePath rs target else (p, o) :: removePath rs target

/-- Path-ID uniqueness predicate (no two directory links share the same `pathId`). -/
def PathIdsUnique : List (Nat × Nat) → Prop
  | []           => True
  | (p, _) :: rs => hasPath rs p = false ∧ PathIdsUnique rs

theorem hasPath_removePath_ne (ps : List (Nat × Nat)) (target q : Nat) (hNe : q ≠ target) :
    hasPath (removePath ps target) q = hasPath ps q := by
  induction ps with
  | nil => rfl
  | cons pair rs ih =>
      rcases pair with ⟨p, o⟩
      dsimp [removePath, hasPath]
      by_cases hpt : p = target
      · subst hpt
        have hNeSym : p ≠ q := fun h => hNe h.symm
        rw [if_pos rfl, if_neg hNeSym]
        exact ih
      · rw [if_neg hpt]
        dsimp [hasPath]
        by_cases hpq : p = q
        · rw [if_pos hpq, if_pos hpq]
        · rw [if_neg hpq, if_neg hpq]
          exact ih

theorem mem_removePath_imp_mem (ps : List (Nat × Nat)) (target : Nat) (p oid : Nat)
    (h : (p, oid) ∈ removePath ps target) : (p, oid) ∈ ps := by
  induction ps with
  | nil => cases h
  | cons pair rs ih =>
      rcases pair with ⟨p0, o0⟩
      dsimp [removePath] at h
      by_cases hEq : p0 = target
      · rw [if_pos hEq] at h
        exact List.Mem.tail _ (ih h)
      · rw [if_neg hEq] at h
        cases h with
        | head => exact List.Mem.head _
        | tail _ hTail => exact List.Mem.tail _ (ih hTail)

theorem removePath_preserves_unique (ps : List (Nat × Nat)) (target : Nat)
    (hUniq : PathIdsUnique ps) : PathIdsUnique (removePath ps target) := by
  induction ps with
  | nil => trivial
  | cons pair rs ih =>
      rcases pair with ⟨p, o⟩
      rcases hUniq with ⟨hNotIn, hRsUniq⟩
      dsimp [removePath]
      by_cases hEq : p = target
      · rw [if_pos hEq]
        exact ih hRsUniq
      · rw [if_neg hEq]
        refine ⟨?_, ih hRsUniq⟩
        rw [hasPath_removePath_ne rs target p hEq]
        exact hNotIn

theorem removePath_of_absent (ps : List (Nat × Nat)) (target : Nat)
    (hAbs : hasPath ps target = false) : removePath ps target = ps := by
  induction ps with
  | nil => rfl
  | cons pair rs ih =>
      rcases pair with ⟨p, o⟩
      dsimp [hasPath] at hAbs
      by_cases hEq : p = target
      · rw [if_pos hEq] at hAbs; cases hAbs
      · rw [if_neg hEq] at hAbs
        dsimp [removePath]
        rw [if_neg hEq, ih hAbs]

theorem removePath_length_pred (ps : List (Nat × Nat)) (target : Nat)
    (hUniq : PathIdsUnique ps) (hHas : hasPath ps target = true) :
    (removePath ps target).length + 1 = ps.length := by
  induction ps with
  | nil => simp [hasPath] at hHas
  | cons pair rs ih =>
      rcases pair with ⟨p, o⟩
      rcases hUniq with ⟨hNotIn, hRsUniq⟩
      dsimp [hasPath] at hHas
      dsimp [removePath]
      by_cases hEq : p = target
      · subst hEq
        rw [if_pos rfl, removePath_of_absent rs p hNotIn]
      · rw [if_neg hEq] at hHas ⊢
        have hLen := ih hRsUniq hHas
        simp [List.length]
        omega

def stepObj (st : NamespaceObjectState) (ev : ObjEvent) : NamespaceObjectState :=
  match ev with
  | .createHardLink newPathId filerHlId =>
      if st.obj.reclaimed = false ∧ st.obj.nlink > 0 ∧ hasPath st.paths newPathId = false then
        let newHl := some (st.obj.hardLinkId.getD filerHlId)
        { obj   := { st.obj with hardLinkId := newHl, nlink := st.obj.nlink + 1 },
          paths := (newPathId, st.obj.objectId) :: st.paths }
      else
        st
  | .unlinkPath pathId =>
      if st.obj.reclaimed = false ∧ hasPath st.paths pathId = true ∧ st.obj.nlink > 0 then
        let remaining := removePath st.paths pathId
        let nlink' := st.obj.nlink - 1
        if nlink' = 0 then
          if st.obj.openRefs > 0 then
            { obj := { st.obj with nlink := 0, isOrphan := true, reclaimed := false }, paths := remaining }
          else
            { obj := { st.obj with nlink := 0, isOrphan := false, reclaimed := true }, paths := remaining }
        else
          { obj := { st.obj with nlink := nlink' }, paths := remaining }
      else
        st
  | .openObject =>
      if st.obj.reclaimed = false ∧ st.obj.nlink > 0 then
        { st with obj := { st.obj with openRefs := st.obj.openRefs + 1 } }
      else
        st
  | .closeObject =>
      if st.obj.reclaimed = false ∧ st.obj.openRefs > 0 then
        let open' := st.obj.openRefs - 1
        if st.obj.nlink = 0 ∧ open' = 0 then
          { st with obj := { st.obj with openRefs := 0, isOrphan := false, reclaimed := true } }
        else
          { st with obj := { st.obj with openRefs := open' } }
      else
        st
  | .graceOrphanSweep graceEnded =>
      if graceEnded = true ∧ st.obj.isOrphan = true ∧ st.obj.nlink = 0 ∧ st.obj.openRefs = 0 then
        { st with obj := { st.obj with isOrphan := false, reclaimed := true } }
      else
        st

def runObj (st : NamespaceObjectState) (trace : List ObjEvent) : NamespaceObjectState :=
  trace.foldl stepObj st

/-- Strengthened v0.3.4 Object Identity & Lifecycle Invariant (all 6 properties!). -/
def ObjInv (birthObjId : Nat) (st : NamespaceObjectState) : Prop :=
  st.obj.objectId = birthObjId ∧
  (∀ p oid, (p, oid) ∈ st.paths → oid = birthObjId) ∧
  PathIdsUnique st.paths ∧
  st.paths.length = st.obj.nlink ∧
  (st.obj.openRefs > 0 → st.obj.reclaimed = false) ∧
  (st.obj.reclaimed = true → st.obj.nlink = 0 ∧ st.obj.openRefs = 0 ∧ st.paths = [])

theorem stepObj_preserves_inv (birthId : Nat) (st : NamespaceObjectState) (ev : ObjEvent)
    (hInv : ObjInv birthId st) : ObjInv birthId (stepObj st ev) := by
  rcases hInv with ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩
  cases ev with
  | createHardLink newPathId filerHlId =>
      dsimp [stepObj]
      split
      · rename_i hCond
        refine ⟨hId, ?_, ⟨hCond.2.2, hUniq⟩, ?_, ?_, ?_⟩
        · intro p oid hMem
          cases hMem with
          | head => exact hId
          | tail _ hTail => exact hPaths p oid hTail
        · simp [List.length, hLen]
        · intro _; exact hCond.1
        · intro hR; rw [hCond.1] at hR; cases hR
      · exact ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩
  | unlinkPath pathId =>
      dsimp [stepObj]
      split
      · rename_i hCond
        have hRemLen : (removePath st.paths pathId).length + 1 = st.paths.length :=
          removePath_length_pred st.paths pathId hUniq hCond.2.1
        have hRemUniq : PathIdsUnique (removePath st.paths pathId) :=
          removePath_preserves_unique st.paths pathId hUniq
        have hRemPaths : ∀ p oid, (p, oid) ∈ removePath st.paths pathId → oid = birthId :=
          fun p oid hM => hPaths p oid (mem_removePath_imp_mem st.paths pathId p oid hM)
        split
        · rename_i hN0
          have hRemEmpty : removePath st.paths pathId = [] := by
            cases hR : removePath st.paths pathId with
            | nil => rfl
            | cons _ _ =>
                rw [hR] at hRemLen
                simp [List.length] at hRemLen
                omega
          split
          · refine ⟨hId, hRemPaths, hRemUniq, by rw [hRemEmpty]; rfl, by intro _; rfl, by intro h; cases h⟩
          · rename_i hNotOpen
            have hOpen0 : st.obj.openRefs = 0 := by omega
            refine ⟨hId, hRemPaths, hRemUniq, by rw [hRemEmpty]; rfl,
                    by intro h; dsimp only at h; omega, by intro _; exact ⟨rfl, hOpen0, hRemEmpty⟩⟩
        · rename_i hNPos
          refine ⟨hId, hRemPaths, hRemUniq, by dsimp only; omega, hOpen, ?_⟩
          intro hR; rw [hCond.1] at hR; cases hR
      · exact ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩
  | openObject =>
      dsimp [stepObj]
      split
      · rename_i hCond
        refine ⟨hId, hPaths, hUniq, hLen, by intro _; exact hCond.1, ?_⟩
        intro hR; rw [hCond.1] at hR; cases hR
      · exact ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩
  | closeObject =>
      dsimp [stepObj]
      split
      · rename_i hCond
        split
        · rename_i hFinal
          have hPathsEmpty : st.paths = [] := by
            cases hP : st.paths with
            | nil => rfl
            | cons _ _ => rw [hP] at hLen; simp [List.length] at hLen; omega
          refine ⟨hId, hPaths, hUniq, hLen, by intro h; dsimp only at h; omega, ?_⟩
          intro _; exact ⟨hFinal.1, rfl, hPathsEmpty⟩
        · refine ⟨hId, hPaths, hUniq, hLen, by intro _; exact hCond.1, ?_⟩
          intro hR; rw [hCond.1] at hR; cases hR
      · exact ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩
  | graceOrphanSweep graceEnded =>
      dsimp [stepObj]
      split
      · rename_i hCond
        have hPathsEmpty : st.paths = [] := by
          cases hP : st.paths with
          | nil => rfl
          | cons _ _ => rw [hP] at hLen; simp [List.length] at hLen; omega
        refine ⟨hId, hPaths, hUniq, hLen, by intro h; dsimp only at h; omega, ?_⟩
        intro _; exact ⟨hCond.2.2.1, hCond.2.2.2, hPathsEmpty⟩
      · exact ⟨hId, hPaths, hUniq, hLen, hOpen, hRecl⟩

theorem runObj_preserves_inv (birthId : Nat) (st : NamespaceObjectState) (trace : List ObjEvent)
    (hInv : ObjInv birthId st) : ObjInv birthId (runObj st trace) := by
  induction trace generalizing st with
  | nil => exact hInv
  | cons ev rest ih => exact ih (stepObj st ev) (stepObj_preserves_inv birthId st ev hInv)

/-- THEOREM FM-06.1 (Complete Object Identity, Link-Count & Open-Unlink Safety):
    For ANY legal lifecycle sequence of hardlinks, unlinks, opens, closes, and grace sweeps:
      1. `objectId = birthId` permanently (`INV-OBJECTID-IMMUTABLE`).
      2. Every active path resolves to `birthId` (`INV-HARDLINK-SAME-OBJECT`).
      3. `paths.length = nlink` at all times (`INV-NLINK-CONSISTENT`).
      4. `openRefs > 0 → reclaimed = false` (`INV-OPEN-UNLINK`).
      5. `reclaimed = true → nlink = 0 ∧ openRefs = 0 ∧ paths = []` (`INV-RECLAIMED-CLEAN`). -/
theorem object_lifecycle_safety
    (birthId : Nat) (initPathId : Nat) (trace : List ObjEvent) :
    let init : NamespaceObjectState := {
      obj := { objectId := birthId, hardLinkId := none, nlink := 1,
               openRefs := 0, isOrphan := false, reclaimed := false },
      paths := [(initPathId, birthId)]
    }
    let final := runObj init trace
    final.obj.objectId = birthId ∧
    (∀ p oid, (p, oid) ∈ final.paths → oid = birthId) ∧
    final.paths.length = final.obj.nlink ∧
    (final.obj.openRefs > 0 → final.obj.reclaimed = false) ∧
    (final.obj.reclaimed = true → final.obj.nlink = 0 ∧ final.obj.openRefs = 0 ∧ final.paths = []) := by
  have hInit : ObjInv birthId {
      obj := { objectId := birthId, hardLinkId := none, nlink := 1,
               openRefs := 0, isOrphan := false, reclaimed := false },
      paths := [(initPathId, birthId)] } := by
    refine ⟨rfl, ?_, ⟨rfl, trivial⟩, rfl, by intro h; dsimp only at h; omega, by intro h; cases h⟩
    intro p oid hMem
    cases hMem with
    | head => rfl
    | tail _ hNil => cases hNil
  have hFinal := runObj_preserves_inv birthId _ trace hInit
  exact ⟨hFinal.1, hFinal.2.1, hFinal.2.2.2.1, hFinal.2.2.2.2.1, hFinal.2.2.2.2.2⟩

end FSALSeaweedFormal.ObjectIdentity
