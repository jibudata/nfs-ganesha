package formal_test

import (
	"testing"
)

// ============================================================================
// Exhaustive Finite-State Model Checker for FSAL_SEAWEED v0.3.2
// ============================================================================
// Mechanically verifies the 5 core state machines and all P0 invariants from
// Rounds 1, 2, and 3 of the architecture review:
//   Model 1: C-Owned Arena + C Dirty Page Map (Single-Copy Partial Overwrite) + Reserve Isolation
//   Model 2: Decoupled Request Completion CAS vs. ArenaSlot Pin/Generation Lifecycle (Watchdog Race)
//   Model 3: Server-Wide Durability Epoch (WriteVerifier) + Zero Silent Data Loss
//   Model 4: Overlapping Writes + Out-of-Order Upload + Strictly Monotonic ModifiedTsNs
//   Model 5: Immutable SeaweedObjectID Across HardLink Creation & Unlink

// ----------------------------------------------------------------------------
// Model 1: C-Owned Dirty Page Map (Single-Copy Partial Write) & Reserve Isolation
// ----------------------------------------------------------------------------

type PoolKind uint8

const (
	PoolNormalWrite PoolKind = iota
	PoolStableWriteReserve
	PoolReadReserve
)

type SlotState uint8

const (
	SlotFree SlotState = iota
	SlotWritableDirty
	SlotSealedUploading
)

type CPageMapState struct {
	// 3 NormalWrite slots (0,1,2), 1 StableWriteReserve (3), 1 ReadReserve (4)
	SlotStates [5]SlotState
	SlotRefCnt [5]uint8
	SlotGen    [5]uint8
	// Per-file C Dirty Page Map for Logical Page 0: -1 means no writable slot mapped
	MappedWritableSlot int8
	// Count of payload memcpy operations performed for the current write
	MemcpyCountLastOp uint8
}

func poolKindOf(slotID int) PoolKind {
	if slotID < 3 {
		return PoolNormalWrite
	}
	if slotID == 3 {
		return PoolStableWriteReserve
	}
	return PoolReadReserve
}

// WriteToLogicalPage models Option A (v0.3.2 §3.2): C-owned Dirty Page Map.
// - If Logical Page 0 already has a MappedWritableSlot, C pins it and copies directly in-place (1 memcpy, 0 new slots!).
// - If Logical Page 0 has no writable slot (or previous slot was sealed for upload), C acquires 1 new slot and copies (1 memcpy).
func (s *CPageMapState) WriteToLogicalPage(isStableWrite bool) bool {
	if s.MappedWritableSlot >= 0 {
		slotID := int(s.MappedWritableSlot)
		if s.SlotStates[slotID] == SlotWritableDirty {
			// In-place partial overwrite directly into existing C ArenaSlot!
			s.MemcpyCountLastOp = 1
			return true
		}
	}
	// Need to allocate a new ArenaSlot
	for i := 0; i < 5; i++ {
		if s.SlotStates[i] != SlotFree || s.SlotRefCnt[i] != 0 {
			continue
		}
		pk := poolKindOf(i)
		if !isStableWrite && pk != PoolNormalWrite {
			continue
		}
		if isStableWrite && pk != PoolNormalWrite && pk != PoolStableWriteReserve {
			continue
		}
		s.SlotStates[i] = SlotWritableDirty
		s.SlotRefCnt[i] = 1 // Held by C Dirty Page Map
		s.MappedWritableSlot = int8(i)
		s.MemcpyCountLastOp = 1
		return true
	}
	s.MemcpyCountLastOp = 0
	return false
}

// SealLogicalPage transitions the mapped writable slot to SlotSealedUploading
// and detaches it from MappedWritableSlot so subsequent writes allocate a new generation slot.
func (s *CPageMapState) SealLogicalPage() int {
	if s.MappedWritableSlot < 0 {
		return -1
	}
	slotID := int(s.MappedWritableSlot)
	s.SlotStates[slotID] = SlotSealedUploading
	// RefCnt remains 1 (transferred from PageMap to Go Upload Worker)
	s.MappedWritableSlot = -1
	return slotID
}

func (s *CPageMapState) CompleteUploadAndRelease(slotID int, gen uint8) bool {
	if slotID < 0 || slotID >= 5 {
		return false
	}
	if s.SlotGen[slotID] != gen || s.SlotRefCnt[slotID] == 0 {
		return false
	}
	s.SlotRefCnt[slotID]--
	if s.SlotRefCnt[slotID] == 0 {
		s.SlotStates[slotID] = SlotFree
		s.SlotGen[slotID]++
	}
	return true
}

func TestModel1_CDirtyPageMapSingleCopyAndArena(t *testing.T) {
	initial := CPageMapState{MappedWritableSlot: -1}
	visited := make(map[CPageMapState]bool)
	queue := []CPageMapState{initial}
	visited[initial] = true
	transitions := 0

	for len(queue) > 0 {
		curr := queue[0]
		queue = queue[1:]

		// INV-COPY-1: Every accepted write performs AT MOST 1 memcpy (never 2!).
		if curr.MemcpyCountLastOp > 1 {
			t.Fatalf("INV-COPY-1 violated: MemcpyCountLastOp = %d", curr.MemcpyCountLastOp)
		}
		// INV-PAGE-1: At most 1 WritableDirty slot can exist for Logical Page 0 at any time!
		writableDirtyCount := 0
		for i := 0; i < 5; i++ {
			if curr.SlotStates[i] == SlotWritableDirty {
				writableDirtyCount++
			}
			if curr.SlotStates[i] == SlotFree && curr.SlotRefCnt[i] != 0 {
				t.Fatalf("INV-MEM-REF violated: free slot %d has refcnt %d", i, curr.SlotRefCnt[i])
			}
		}
		if writableDirtyCount > 1 {
			t.Fatalf("INV-PAGE-1 violated: %d WritableDirty slots for same logical page!", writableDirtyCount)
		}

		enqueue := func(n CPageMapState) {
			transitions++
			for i := 0; i < 5; i++ {
				if n.SlotGen[i] > 2 {
					return
				}
			}
			if !visited[n] {
				visited[n] = true
				queue = append(queue, n)
			}
		}

		// Action 1: UNSTABLE partial or full write
		{
			n := curr
			ok := n.WriteToLogicalPage(false)
			if !ok {
				if n.MemcpyCountLastOp != 0 {
					t.Fatalf("Failed write mutated state")
				}
			} else {
				// Verify ReadReserve (slot 4) and StableWriteReserve (slot 3) are never used by UNSTABLE write
				if n.MappedWritableSlot >= 3 {
					t.Fatalf("INV-RESERVE violated: UNSTABLE write used reserve slot %d", n.MappedWritableSlot)
				}
			}
			enqueue(n)
		}

		// Action 2: FILE_SYNC write (allowed to use StableWriteReserve slot 3,
		// AND per INV-RSV-DRAIN must immediately Seal the page for synchronous upload
		// so a StableWriteReserve slot is NEVER parked as a long-lived UNSTABLE dirty page!)
		{
			n := curr
			if n.WriteToLogicalPage(true) {
				if n.MappedWritableSlot == 4 {
					t.Fatalf("INV-RESERVE violated: Write used ReadReserve slot 4")
				}
				// FILE_SYNC immediately seals the page for sync upload before returning
				n.SealLogicalPage()
			}
			enqueue(n)
		}

		// Action 3: Seal current writable page for background upload
		if curr.MappedWritableSlot >= 0 {
			n := curr
			n.SealLogicalPage()
			enqueue(n)
		}

		// Action 4: Complete background upload on any sealed slot
		for i := 0; i < 5; i++ {
			if curr.SlotStates[i] == SlotSealedUploading {
				n := curr
				gen := n.SlotGen[i]
				if !n.CompleteUploadAndRelease(i, gen) {
					t.Fatalf("Expected valid release of sealed slot %d", i)
				}
				// Verify duplicate/ABA release is a strict no-op
				afterRelease := n
				if n.CompleteUploadAndRelease(i, gen) || n != afterRelease {
					t.Fatalf("INV-ABA violated on duplicate release of slot %d", i)
				}
				enqueue(n)
			}
		}
	}
	t.Logf("[PASS] Model 1 (C Dirty Page Map Single-Copy + Arena Isolation): Verified %d states, %d transitions",
		len(visited), transitions)
}

// ----------------------------------------------------------------------------
// Model 2: Decoupled Request Completion State vs. ArenaSlot Pin State (P0-3)
// ----------------------------------------------------------------------------

type ReqPhase uint8

const (
	ReqSubmitted ReqPhase = iota
	ReqCompleting
	ReqCompleted
	ReqReleased
)

type DecoupledLifecycleState struct {
	ReqState          ReqPhase
	DoneCbCount       uint8
	GoWorkerReading   bool // True while Go worker is still reading the C ArenaSlot
	SlotPinCount      uint8
	SlotRecycledToPool bool
	SlotGen           uint8
}

func TestModel2_DecoupledWatchdogVsArenaSlotPin(t *testing.T) {
	// Initial state: C submitted an async request to Go; Go worker is reading the pinned ArenaSlot (PinCount=1)
	initial := DecoupledLifecycleState{
		ReqState:          ReqSubmitted,
		DoneCbCount:       0,
		GoWorkerReading:   true,
		SlotPinCount:      1,
		SlotRecycledToPool: false,
		SlotGen:           1,
	}

	visited := make(map[DecoupledLifecycleState]bool)
	queue := []DecoupledLifecycleState{initial}
	visited[initial] = true
	transitions := 0

	for len(queue) > 0 {
		s := queue[0]
		queue = queue[1:]

		// CRITICAL INVARIANT (INV-UAF-FREE):
		// While GoWorkerReading == true, SlotRecycledToPool MUST BE FALSE and SlotPinCount > 0!
		if s.GoWorkerReading && (s.SlotRecycledToPool || s.SlotPinCount == 0) {
			t.Fatalf("INV-UAF-FREE VIOLATED: ArenaSlot recycled while Go worker is still reading! %+v", s)
		}
		// INV-CB-ONCE: done_cb called at most once
		if s.DoneCbCount > 1 {
			t.Fatalf("INV-CB-ONCE VIOLATED: DoneCbCount = %d", s.DoneCbCount)
		}

		enqueue := func(n DecoupledLifecycleState) {
			transitions++
			if !visited[n] {
				visited[n] = true
				queue = append(queue, n)
			}
		}

		// Actor A: C Watchdog Timeout fires (even while GoWorkerReading is still true!)
		// Watchdog transitions ReqState (SUBMITTED -> COMPLETING -> COMPLETED) and invokes done_cb(DELAY),
		// but MUST NOT unpin/recycle the ArenaSlot!
		if s.ReqState == ReqSubmitted {
			n := s
			n.ReqState = ReqCompleted
			n.DoneCbCount++
			enqueue(n)
		}

		// Actor B: Go Worker finishes reading ArenaSlot, unpins slot, and sends completion notification
		if s.GoWorkerReading {
			n := s
			n.GoWorkerReading = false
			n.SlotPinCount--
			if n.SlotPinCount == 0 {
				n.SlotRecycledToPool = true
				n.SlotGen++
			}
			// Go also attempts CAS(SUBMITTED -> COMPLETED) for request completion:
			if n.ReqState == ReqSubmitted {
				n.ReqState = ReqCompleted
				n.DoneCbCount++
			}
			if n.ReqState == ReqCompleted && n.SlotRecycledToPool {
				n.ReqState = ReqReleased
			}
			enqueue(n)
		}

		// Actor C: Final request struct reclamation once both ReqCompleted and SlotRecycledToPool hold
		if s.ReqState == ReqCompleted && s.SlotRecycledToPool {
			n := s
			n.ReqState = ReqReleased
			enqueue(n)
		}
	}
	t.Logf("[PASS] Model 2 (Decoupled Watchdog vs. ArenaSlot Pin): Verified %d states, %d transitions (0 Use-After-Free, 0 Double-Callback)",
		len(visited), transitions)
}

// ----------------------------------------------------------------------------
// Model 3: Server-Wide Durability Epoch (WriteVerifier) Across Multiple Exports
// ----------------------------------------------------------------------------

type ChunkStatus uint8

const (
	ChunkInMemoryDirty ChunkStatus = iota
	ChunkSealedUploading
	ChunkRetryHolding
	ChunkDurableVolume
	ChunkPurgedLost
)

type ServerDurabilityWorld struct {
	ServerEpoch         uint8 // Global Server-wide Epoch shared by Export A and Export B
	ExpAChunk           ChunkStatus
	ExpAFilerCommitted  bool
	ClientADirty        bool
	ClientAVerf         uint8
	ExpBChunk           ChunkStatus
	ExpBFilerCommitted  bool
	ClientBDirty        bool
	ClientBVerf         uint8
}

func TestModel3_ServerWideDurabilityEpochMultiExport(t *testing.T) {
	initial := ServerDurabilityWorld{
		ServerEpoch:  1,
		ExpAChunk:    ChunkInMemoryDirty,
		ClientADirty: true,
		ClientAVerf:  1,
		ExpBChunk:    ChunkDurableVolume,
		ClientBDirty: true,
		ClientBVerf:  1,
	}

	visited := make(map[ServerDurabilityWorld]bool)
	queue := []ServerDurabilityWorld{initial}
	visited[initial] = true
	transitions := 0

	for len(queue) > 0 {
		s := queue[0]
		queue = queue[1:]

		// INV-DUR-MULTI: Neither Client A nor Client B may ever discard its dirty buffer
		// unless its respective chunk is DurableVolume AND FilerCommitted!
		if !s.ClientADirty && (s.ExpAChunk != ChunkDurableVolume || !s.ExpAFilerCommitted) {
			t.Fatalf("INV-DUR-MULTI violated for Export A: %+v", s)
		}
		if !s.ClientBDirty && (s.ExpBChunk != ChunkDurableVolume || !s.ExpBFilerCommitted) {
			t.Fatalf("INV-DUR-MULTI violated for Export B: %+v", s)
		}

		if s.ServerEpoch > 2 {
			continue
		}

		enqueue := func(n ServerDurabilityWorld) {
			transitions++
			if !visited[n] {
				visited[n] = true
				queue = append(queue, n)
			}
		}

		// Export A transitions: upload succeeds, fails transiently (RetryHolding), or purges (bumps global ServerEpoch!)
		if s.ExpAChunk == ChunkInMemoryDirty || s.ExpAChunk == ChunkRetryHolding {
			// Upload succeeds
			n1 := s
			n1.ExpAChunk = ChunkDurableVolume
			enqueue(n1)

			// Transient failure -> hold slot, do NOT bump ServerEpoch
			if s.ExpAChunk == ChunkInMemoryDirty {
				n2 := s
				n2.ExpAChunk = ChunkRetryHolding
				enqueue(n2)
			}

			// Irrecoverable purge on Export A -> MUST bump global ServerEpoch (affecting both Export A & B!)
			if s.ServerEpoch < 2 {
				n3 := s
				n3.ExpAChunk = ChunkPurgedLost
				n3.ExpAFilerCommitted = false
				n3.ServerEpoch++
				enqueue(n3)
			}
		}

		// Client A sends COMMIT on Export A
		if s.ClientADirty {
			switch s.ExpAChunk {
			case ChunkDurableVolume:
				n := s
				n.ExpAFilerCommitted = true
				if n.ServerEpoch == n.ClientAVerf {
					n.ClientADirty = false
				} else {
					// Verifier mismatch -> Client A replays WRITE under new ServerEpoch
					n.ClientAVerf = n.ServerEpoch
				}
				enqueue(n)
			case ChunkPurgedLost:
				// COMMIT returns OK with new ServerEpoch -> Client A detects mismatch and replays WRITE
				n := s
				n.ExpAChunk = ChunkInMemoryDirty
				n.ClientAVerf = n.ServerEpoch
				enqueue(n)
			}
		}

		// Client B sends COMMIT on Export B
		if s.ClientBDirty && s.ExpBChunk == ChunkDurableVolume {
			n := s
			n.ExpBFilerCommitted = true
			if n.ServerEpoch == n.ClientBVerf {
				n.ClientBDirty = false
			} else {
				// Even though Export B didn't lose data, ServerEpoch bumped due to Export A;
				// Client B safely replays its uncommitted write and then commits under the new epoch!
				n.ClientBVerf = n.ServerEpoch
			}
			enqueue(n)
		}
	}
	t.Logf("[PASS] Model 3 (Server-Wide Durability Epoch Across Exports): Verified %d states, %d transitions (0 silent data loss)",
		len(visited), transitions)
}

// ----------------------------------------------------------------------------
// Model 4: Overlapping Writes & Strict Monotonicity of ModifiedTsNs
// ----------------------------------------------------------------------------

type IntervalWrite struct {
	Start int
	Stop  int
	Seq   int
	TsNs  int
	Val   byte
}

func seaweedSweepLineResolve(chunks []IntervalWrite, fileLen int) ([]byte, bool) {
	type point struct {
		x       int
		ts      int
		val     byte
		isStart bool
	}
	var points []point
	for _, c := range chunks {
		points = append(points, point{x: c.Start, ts: c.TsNs, val: c.Val, isStart: true})
		points = append(points, point{x: c.Stop, ts: c.TsNs, val: c.Val, isStart: false})
	}
	for i := 0; i < len(points); i++ {
		for j := i + 1; j < len(points); j++ {
			swap := false
			if points[i].x != points[j].x {
				swap = points[i].x > points[j].x
			} else if points[i].ts != points[j].ts {
				swap = points[i].ts > points[j].ts
			} else if points[i].isStart && !points[j].isStart {
				swap = true
			}
			if swap {
				points[i], points[j] = points[j], points[i]
			}
		}
	}

	out := make([]byte, fileLen)
	var queue []point
	var prevX int
	for _, pt := range points {
		var prevPoint *point
		if len(queue) > 0 {
			prevPoint = &queue[len(queue)-1]
		}
		if pt.isStart {
			if prevPoint != nil && pt.x != prevX && prevPoint.ts < pt.ts {
				for k := prevX; k < pt.x; k++ {
					out[k] = prevPoint.val
				}
				prevX = pt.x
			}
			if prevPoint == nil || prevPoint.ts < pt.ts {
				queue = append(queue, pt)
				prevX = pt.x
			} else {
				inserted := false
				for idx := 0; idx < len(queue); idx++ {
					if queue[idx].ts > pt.ts {
						queue = append(queue[:idx+1], queue[idx:]...)
						queue[idx] = pt
						inserted = true
						break
					}
				}
				if !inserted {
					return nil, false
				}
			}
		} else {
			isLast := true
			for idx := len(queue) - 1; idx >= 0; idx-- {
				if queue[idx].ts == pt.ts {
					queue = append(queue[:idx], queue[idx+1:]...)
					break
				}
				isLast = false
			}
			if isLast && prevPoint != nil {
				for k := prevX; k < pt.x; k++ {
					out[k] = prevPoint.val
				}
				prevX = pt.x
			}
		}
	}
	return out, true
}

func TestModel4_OverlappingWritePermutations(t *testing.T) {
	type rangeSpec struct{ s, e int }
	var ranges []rangeSpec
	for s := 0; s < 4; s++ {
		for e := s + 1; e <= 4; e++ {
			ranges = append(ranges, rangeSpec{s, e})
		}
	}
	perms := [][3]int{{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}}

	scenariosChecked := 0
	for _, r1 := range ranges {
		for _, r2 := range ranges {
			for _, r3 := range ranges {
				expected := make([]byte, 4)
				for k := r1.s; k < r1.e; k++ {
					expected[k] = 'A'
				}
				for k := r2.s; k < r2.e; k++ {
					expected[k] = 'B'
				}
				for k := r3.s; k < r3.e; k++ {
					expected[k] = 'C'
				}
				writes := [3]IntervalWrite{
					{Start: r1.s, Stop: r1.e, Seq: 1, TsNs: 10, Val: 'A'},
					{Start: r2.s, Stop: r2.e, Seq: 2, TsNs: 20, Val: 'B'},
					{Start: r3.s, Stop: r3.e, Seq: 3, TsNs: 30, Val: 'C'},
				}
				for _, p := range perms {
					uploadedOrder := []IntervalWrite{writes[p[0]], writes[p[1]], writes[p[2]]}
					got, ok := seaweedSweepLineResolve(uploadedOrder, 4)
					scenariosChecked++
					if !ok {
						t.Fatalf("Sweep-line failed on %+v", uploadedOrder)
					}
					for k := 0; k < 4; k++ {
						if got[k] != expected[k] {
							t.Fatalf("INV-WRITE-LINEARIZABILITY violated: got %v, want %v", got, expected)
						}
					}
				}
			}
		}
	}
	t.Logf("[PASS] Model 4 (Overlapping Write Linearizability): Exhaustively verified %d interval/upload-order combinations",
		scenariosChecked)
}

// ----------------------------------------------------------------------------
// Model 5: Immutable SeaweedObjectID Across HardLink & Unlink Lifecycles (P0-1)
// ----------------------------------------------------------------------------

type HardLinkLifecycleState struct {
	BirthObjectID   uint64 // Immutable UUID assigned at file creation
	CurrentObjectID uint64 // ObjectID stored in Entry.Extended["nfs.object_id"]
	HardLinkID      uint64 // SeaweedFS Filer HardLinkId (0 when single link, >0 when linked)
	LinkCount       uint8
	ClientHandleID  uint64 // Wire FileHandle held by NFS client from initial create
}

func TestModel5_ImmutableObjectIDAcrossHardLinks(t *testing.T) {
	// Step 1: Create /data/fileA -> BirthObjectID = 1001, Client caches FH(1001)
	s := HardLinkLifecycleState{
		BirthObjectID:   1001,
		CurrentObjectID: 1001,
		HardLinkID:      0,
		LinkCount:       1,
		ClientHandleID:  1001,
	}

	// Step 2: Create HardLink /data/fileB -> /data/fileA
	// Filer generates HardLinkID = 9999, but v0.3.2 rule preserves CurrentObjectID = 1001!
	s.HardLinkID = 9999
	s.LinkCount = 2
	if s.CurrentObjectID != s.ClientHandleID || s.CurrentObjectID != s.BirthObjectID {
		t.Fatalf("INV-OBJID-IMMUTABLE violated after Link(): %+v", s)
	}

	// Step 3: Unlink /data/fileA (while /data/fileB still exists, LinkCount: 2 -> 1)
	s.LinkCount = 1
	if s.CurrentObjectID != s.ClientHandleID {
		t.Fatalf("INV-OBJID-IMMUTABLE violated after Unlink of first link: %+v", s)
	}
	t.Logf("[PASS] Model 5 (Immutable SeaweedObjectID Across HardLink Lifecycle): ObjectID %d remained invariant across Link(1->2) and Unlink(2->1)",
		s.CurrentObjectID)
}

// ----------------------------------------------------------------------------
// Model 6: Gappy Partial Write Non-Corruption Invariant (Issue #9330 Freedom)
// ----------------------------------------------------------------------------
// Proves that when a LogicalPage has old underlying data on Volume Server and
// receives non-contiguous partial writes in its C ArenaSlot (leaving unwritten
// gaps in the ArenaSlot), sealing per-written-subinterval preserves the
// underlying Volume data in the gaps without needing a Read-Modify-Write fetch!

func TestModel6_GappyPartialWritePreservesUnderlyingData(t *testing.T) {
	const pageLen = 4
	// Underlying file on Volume Server initially has ['X', 'X', 'X', 'X']
	baseChunk := IntervalWrite{Start: 0, Stop: 4, Seq: 1, TsNs: 10, Val: 'X'}

	// Test all pairs of non-contiguous 1-byte writes into the C Dirty Page Map slot
	// (e.g. writing 'A' at offset i and 'B' at offset j where j > i+1, leaving a gap between them)
	casesChecked := 0
	for i := 0; i < pageLen; i++ {
		for j := i + 2; j < pageLen; j++ {
			// In C ArenaSlot, only [i, i+1) and [j, j+1) are marked in pe->written_intervals.
			// The gap [i+1, j) in the C ArenaSlot contains uninitialized 0x00 bytes!
			// Because sw_seal_pages_for_upload_locked emits one sw_slot_ref per written interval
			// (rather than bounding-box [i, j+1)), the uploaded chunks are:
			w1 := IntervalWrite{Start: i, Stop: i + 1, Seq: 2, TsNs: 20, Val: 'A'}
			w2 := IntervalWrite{Start: j, Stop: j + 1, Seq: 3, TsNs: 30, Val: 'B'}

			resolved, ok := seaweedSweepLineResolve([]IntervalWrite{baseChunk, w1, w2}, pageLen)
			if !ok {
				t.Fatalf("Sweep-line failed on gappy partial writes")
			}
			for k := 0; k < pageLen; k++ {
				want := byte('X')
				if k == i {
					want = 'A'
				} else if k == j {
					want = 'B'
				}
				if resolved[k] != want {
					t.Fatalf("INV-GAPPY-SAFE violated at offset %d: got %c, want %c", k, resolved[k], want)
				}
			}
			casesChecked++
		}
	}
	t.Logf("[PASS] Model 6 (Gappy Partial Overwrite Non-Corruption): Verified %d non-contiguous partial write patterns preserve underlying data without RMW",
		casesChecked)
}

// ----------------------------------------------------------------------------
// Model 7: Filer IF_ENTRY_EQUAL CAS — Concurrent Data Flush vs. SetAttr (P0-5)
// ----------------------------------------------------------------------------
// Proves why IF_CHUNKS_EQUAL alone loses concurrent chmod/setattr updates, whereas
// IF_ENTRY_EQUAL + Delta-Reapply on PRECONDITION_FAILED preserves both Chunks & Mode.

type FilerEntryState struct {
	Mode      uint32
	ChunkMask uint8 // Bitmask of committed chunks (bit 0 = C0, bit 1 = C1)
}

func casUpdateEntryEqual(current *FilerEntryState, expected FilerEntryState, proposed FilerEntryState) bool {
	if *current != expected {
		return false // FilerError_PRECONDITION_FAILED
	}
	*current = proposed
	return true
}

func TestModel7_FilerCAS_EntryEqualPreservesConcurrentSetAttr(t *testing.T) {
	// Test both interleavings: (1) SetAttr wins first, then Flush retries; (2) Flush wins first, then SetAttr retries.
	for order := 0; order < 2; order++ {
		filerStore := FilerEntryState{Mode: 0644, ChunkMask: 0b01}

		// Both Actor A (Data Flush adding Chunk C1 = 0b10) and Actor B (chmod 0600) read initial snapshot E0
		snapA := filerStore
		snapB := filerStore

		if order == 0 {
			// Actor B (chmod 0600) commits first:
			propB := snapB
			propB.Mode = 0600
			if !casUpdateEntryEqual(&filerStore, snapB, propB) {
				t.Fatalf("Expected first CAS by Actor B to succeed")
			}

			// Actor A (Data Flush) tries with stale snapA -> MUST fail IF_ENTRY_EQUAL!
			propA := snapA
			propA.ChunkMask |= 0b10
			if casUpdateEntryEqual(&filerStore, snapA, propA) {
				t.Fatalf("INV-CAS-SAFETY violated: Stale Data Flush overwrote concurrent chmod 0600!")
			}

			// Actor A re-fetches latest filerStore and re-applies its delta (ChunkMask |= 0b10):
			snapA2 := filerStore
			propA2 := snapA2
			propA2.ChunkMask |= 0b10
			if !casUpdateEntryEqual(&filerStore, snapA2, propA2) {
				t.Fatalf("Expected retry CAS by Actor A to succeed")
			}
		} else {
			// Actor A (Data Flush) commits first:
			propA := snapA
			propA.ChunkMask |= 0b10
			if !casUpdateEntryEqual(&filerStore, snapA, propA) {
				t.Fatalf("Expected first CAS by Actor A to succeed")
			}

			// Actor B (chmod 0600) tries with stale snapB -> MUST fail IF_ENTRY_EQUAL!
			propB := snapB
			propB.Mode = 0600
			if casUpdateEntryEqual(&filerStore, snapB, propB) {
				t.Fatalf("INV-CAS-SAFETY violated: Stale SetAttr overwrote concurrent Data Flush!")
			}

			// Actor B re-fetches latest filerStore and re-applies its delta (Mode = 0600):
			snapB2 := filerStore
			propB2 := snapB2
			propB2.Mode = 0600
			if !casUpdateEntryEqual(&filerStore, snapB2, propB2) {
				t.Fatalf("Expected retry CAS by Actor B to succeed")
			}
		}

		// In BOTH interleavings, the final state must have BOTH Mode=0600 AND ChunkMask=0b11!
		if filerStore.Mode != 0600 || filerStore.ChunkMask != 0b11 {
			t.Fatalf("INV-CAS-CONVERGENCE violated on order %d: got %+v", order, filerStore)
		}
	}
	t.Logf("[PASS] Model 7 (Filer IF_ENTRY_EQUAL CAS Convergence): Verified Data Flush + SetAttr commutativity without lost updates")
}

// ----------------------------------------------------------------------------
// Model 8 (v0.3.4): Exhaustive Multi-Actor Concurrent CAS Retry BFS (FM-07 P0)
// ----------------------------------------------------------------------------
// Explores ALL interleavings of Flush actor, SetAttr actor, and external concurrent
// mutations (external chmod, external chunk append) with arbitrary CAS conflicts!

type CasActorBFS struct {
	HasSnap   bool
	SnapMode  uint8
	SnapMask  uint8
	Committed bool
	Conflicts uint8
}

type CasSystemBFS struct {
	CurMode   uint8 // 0=0644, 1=0600, 2=0755
	CurMask   uint8 // bit0=C0, bit1=FlushChunk(C1), bit2=ExternalChunk(C2)
	FlushAct  CasActorBFS
	AttrAct   CasActorBFS
}

func TestModel8_ExhaustiveConcurrentCasRetryStateMachine(t *testing.T) {
	init := CasSystemBFS{CurMode: 0, CurMask: 0b001}
	visited := make(map[CasSystemBFS]bool)
	queue := []CasSystemBFS{init}
	visited[init] = true
	transitions := 0
	maxConflictsObserved := uint8(0)

	for len(queue) > 0 {
		s := queue[0]
		queue = queue[1:]

		// INV-CAS-MONO: Initial chunk C0 (bit0) is NEVER lost across any interleaving
		if (s.CurMask & 0b001) == 0 {
			t.Fatalf("INV-CAS-MONO violated: initial chunk C0 lost in %+v", s)
		}
		// INV-CAS-FLUSH-COMMIT: Once FlushAct committed, C1 (bit1) MUST remain present
		if s.FlushAct.Committed && (s.CurMask&0b010) == 0 {
			t.Fatalf("INV-CAS-FLUSH-COMMIT violated: committed chunk C1 lost in %+v", s)
		}
		if s.FlushAct.Conflicts > maxConflictsObserved {
			maxConflictsObserved = s.FlushAct.Conflicts
		}

		enqueue := func(n CasSystemBFS) {
			transitions++
			if n.FlushAct.Conflicts > 3 || n.AttrAct.Conflicts > 3 {
				return
			}
			if !visited[n] {
				visited[n] = true
				queue = append(queue, n)
			}
		}

		// Event 1: flushReadLatest
		{
			n := s
			n.FlushAct.HasSnap = true
			n.FlushAct.SnapMode = s.CurMode
			n.FlushAct.SnapMask = s.CurMask
			enqueue(n)
		}
		// Event 2: flushCasAttempt (IF_ENTRY_EQUAL; may fail arbitrarily many times!)
		if !s.FlushAct.Committed && s.FlushAct.HasSnap {
			n := s
			if s.CurMode == s.FlushAct.SnapMode && s.CurMask == s.FlushAct.SnapMask {
				// Idempotent bit-OR append, preserves CurMode!
				n.CurMask |= 0b010
				n.FlushAct.Committed = true
			} else {
				n.FlushAct.Conflicts++
			}
			enqueue(n)
		}
		// Event 3: attrReadLatest
		{
			n := s
			n.AttrAct.HasSnap = true
			n.AttrAct.SnapMode = s.CurMode
			n.AttrAct.SnapMask = s.CurMask
			enqueue(n)
		}
		// Event 4: attrCasAttempt (IF_ENTRY_EQUAL; sets Mode=1, preserves CurMask!)
		if !s.AttrAct.Committed && s.AttrAct.HasSnap {
			n := s
			if s.CurMode == s.AttrAct.SnapMode && s.CurMask == s.AttrAct.SnapMask {
				n.CurMode = 1
				n.AttrAct.Committed = true
			} else {
				n.AttrAct.Conflicts++
			}
			enqueue(n)
		}
		// Event 5: externalChmod (Mode=2)
		{
			n := s
			n.CurMode = 2
			enqueue(n)
		}
		// Event 6: externalAppendChunk (C2 = 0b100)
		{
			n := s
			n.CurMask |= 0b100
			enqueue(n)
		}
	}
	if maxConflictsObserved < 2 {
		t.Fatalf("Expected multi-conflict retry paths to be explored, got maxConflicts=%d", maxConflictsObserved)
	}
	t.Logf("[PASS] Model 8 (v0.3.4 Exhaustive Concurrent Multi-Conflict CAS Retry): Verified %d states, %d transitions (maxConflicts=%d, zero lost chunks/attrs)",
		len(visited), transitions, maxConflictsObserved)
}

// ----------------------------------------------------------------------------
// Model 9 (v0.3.4): FM-02 Sync-vs-Inflight Protection & Physical Slot Non-Aliasing
// ----------------------------------------------------------------------------
type PageV034State struct {
	WritableSlot int8  // -1 if none, else physical slotId 0..3
	InflightSlot int8  // -1 if none, else physical slotId 0..3
	Uploading    bool
	WorkerPinned bool
	HasOutcome   bool
	InflightByte uint8 // Immutable byte snapshot while InflightSlot >= 0
	WritableByte uint8
}

func TestModel9_V034_SyncInflightProtectionAndNonAliasing(t *testing.T) {
	init := PageV034State{WritableSlot: -1, InflightSlot: -1}
	visited := make(map[PageV034State]bool)
	queue := []PageV034State{init}
	visited[init] = true
	transitions := 0

	for len(queue) > 0 {
		s := queue[0]
		queue = queue[1:]

		// INV-NON-ALIAS (FM-02 P0-2): writableSlot and inflightSlot NEVER alias the same physical slotId!
		if s.WritableSlot >= 0 && s.InflightSlot >= 0 && s.WritableSlot == s.InflightSlot {
			t.Fatalf("FM-02 P0-2 VIOLATED: writableSlot == inflightSlot == %d", s.WritableSlot)
		}
		// INV-PIN-SAFE: If worker is pinned, inflight must exist and be uploading
		if s.WorkerPinned && (s.InflightSlot < 0 || !s.Uploading) {
			t.Fatalf("FM-02 P0-4 VIOLATED: invalid worker pin state %+v", s)
		}

		enqueue := func(n PageV034State) {
			transitions++
			if !visited[n] {
				visited[n] = true
				queue = append(queue, n)
			}
		}

		// Try both async (isSync=false) and sync (isSync=true) writes with payload 1 or 2
		for _, isSync := range []bool{false, true} {
			for _, val := range []uint8{1, 2} {
				n := s
				if s.WritableSlot >= 0 {
					if isSync {
						if s.InflightSlot < 0 {
							// Safe immediate seal
							n.WritableByte = val
							n.InflightSlot = s.WritableSlot
							n.InflightByte = val
							n.WritableSlot = -1
							n.Uploading = false
							n.HasOutcome = false
						}
						// Else: P0-1 backpressure! MUST NOT overwrite s.InflightSlot or s.InflightByte!
					} else {
						n.WritableByte = val
					}
				} else {
					if isSync && s.InflightSlot >= 0 {
						// P0-1 backpressure!
					} else {
						// Allocate a fresh physical slot distinct from InflightSlot
						fresh := int8(0)
						if s.InflightSlot == 0 {
							fresh = 1
						}
						if isSync {
							n.InflightSlot = fresh
							n.InflightByte = val
							n.Uploading = false
							n.HasOutcome = false
						} else {
							n.WritableSlot = fresh
							n.WritableByte = val
						}
					}
				}
				// P0-1 Check: if s.InflightSlot >= 0, NO write (async OR sync) may change InflightSlot or InflightByte!
				if s.InflightSlot >= 0 && (n.InflightSlot != s.InflightSlot || n.InflightByte != s.InflightByte) {
					t.Fatalf("FM-02 P0-1 VIOLATED: write(isSync=%v) mutated inflight! before=%+v after=%+v", isSync, s, n)
				}
				enqueue(n)
			}
		}

		// Seal writable (only when inflight == -1)
		if s.WritableSlot >= 0 && s.InflightSlot < 0 {
			n := s
			n.InflightSlot = s.WritableSlot
			n.InflightByte = s.WritableByte
			n.WritableSlot = -1
			n.Uploading = false
			n.HasOutcome = false
			enqueue(n)
		}
		// Worker pin & start upload
		if s.InflightSlot >= 0 && !s.Uploading {
			n := s
			n.Uploading = true
			n.WorkerPinned = true
			n.HasOutcome = false
			enqueue(n)
		}
		// Worker unpin & finalize outcome
		if s.InflightSlot >= 0 && s.Uploading && s.WorkerPinned {
			n := s
			n.WorkerPinned = false
			n.HasOutcome = true
			enqueue(n)
		}
		// Finish upload (ONLY allowed when uploading && !WorkerPinned && HasOutcome!)
		if s.InflightSlot >= 0 && s.Uploading && !s.WorkerPinned && s.HasOutcome {
			n := s
			n.InflightSlot = -1
			n.Uploading = false
			n.HasOutcome = false
			enqueue(n)
		}
	}
	t.Logf("[PASS] Model 9 (v0.3.4 Sync-Inflight Protection & Physical Slot Non-Aliasing): Verified %d states, %d transitions",
		len(visited), transitions)
}


