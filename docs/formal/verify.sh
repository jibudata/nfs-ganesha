#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== [1/4] Lean Toolchain Version ==="
lean --version
lake --version

echo "=== [2/4] Forbidden Proof Escape Scan (sorry / admit / axiom) ==="
# Strip comments? No — enforce strict absence of standalone keywords in Lean files
if grep -rnE '(^|[^A-Za-z0-9_])(sorry|admit|axiom)([^A-Za-z0-9_]|$)' FSALSeaweedFormal/ | grep -vE '^\s*--'; then
  echo "FAIL: Forbidden proof escape keyword found in FSALSeaweedFormal/!"
  exit 1
fi
echo "PASS: Zero sorry / admit / axiom in FSALSeaweedFormal/"

echo "=== [3/4] Mechanical Proof Compilation (lake build) ==="
lake clean >/dev/null 2>&1 || true
AUDIT_LOG="$(mktemp)"
trap 'rm -f "$AUDIT_LOG"' EXIT

lake build 2>&1 | tee "$AUDIT_LOG"

echo "=== [4/4] Automated Axiom Whitelist Gate ==="
# Also run explicit root check via lake env lean to guarantee #print axioms output is captured freshly
lake env lean FSALSeaweedFormal.lean > "$AUDIT_LOG" 2>&1
cat "$AUDIT_LOG"

python3 - "$AUDIT_LOG" <<'PYEOF'
import re, sys

log_path = sys.argv[1]
text = open(log_path, "r", encoding="utf-8").read()

ALLOWED = {"propext", "Classical.choice", "Quot.sound"}
EXPECTED_THEOREMS = [
    "FSALSeaweedFormal.Arena.no_free_while_pinned_or_owned",
    "FSALSeaweedFormal.Arena.owner_token_isolation",
    "FSALSeaweedFormal.Arena.worker_pin_token_isolation",
    "FSALSeaweedFormal.Arena.permanent_aba_immunity",
    "FSALSeaweedFormal.Arena.pool_capacity_partition",
    "FSALSeaweedFormal.Arena.allocUnstablePool_isolates_reserves",
    "FSALSeaweedFormal.Arena.allocStablePool_policy",
    "FSALSeaweedFormal.Arena.allocReadPool_isolates_writes",
    "FSALSeaweedFormal.Arena.sequential_alloc_no_duplicate_slotId",
    "FSALSeaweedFormal.DirtyPageMap.partial_overwrite_byte_semantics",
    "FSALSeaweedFormal.DirtyPageMap.write_never_overwrites_or_mutates_inflight",
    "FSALSeaweedFormal.DirtyPageMap.runPageMap_preserves_all_invariants",
    "FSALSeaweedFormal.DirtyPageMap.writable_and_inflight_physically_distinct",
    "FSALSeaweedFormal.DirtyPageMap.finishUpload_blocked_while_pinned_or_undetermined",
    "FSALSeaweedFormal.AsyncLifecycle.callback_at_most_once",
    "FSALSeaweedFormal.AsyncLifecycle.completing_blocks_watchdog_and_non_winners",
    "FSALSeaweedFormal.AsyncLifecycle.worker_pin_isolation_in_async",
    "FSALSeaweedFormal.AsyncLifecycle.no_recycle_while_pinned_or_owned",
    "FSALSeaweedFormal.DurabilityEpoch.incomplete_durability_commit_returns_delay",
    "FSALSeaweedFormal.DurabilityEpoch.purged_loss_commit_exposes_mismatch",
    "FSALSeaweedFormal.DurabilityEpoch.zero_silent_data_loss_all_traces",
    "FSALSeaweedFormal.ChunkOrdering.generator_guarantees_seq_ts_equivalence",
    "FSALSeaweedFormal.ChunkOrdering.older_write_never_overwrites_newer_write",
    "FSALSeaweedFormal.ChunkOrdering.out_of_order_upload_swap_invariant",
    "FSALSeaweedFormal.ChunkOrdering.cross_file_isolation",
    "FSALSeaweedFormal.ChunkOrdering.chunk_resolution_ordering_theorem",
    "FSALSeaweedFormal.ObjectIdentity.object_lifecycle_safety",
    "FSALSeaweedFormal.FilerCAS.flush_delta_idempotent",
    "FSALSeaweedFormal.FilerCAS.truncate_delta_semantics",
    "FSALSeaweedFormal.FilerCAS.cas_attempts_non_interference",
    "FSALSeaweedFormal.FilerCAS.concurrent_cas_trace_safety",
    "FSALSeaweedFormal.FilerCAS.quiescent_retry_converges",
]

found = {}
for line in text.splitlines():
    m_dep = re.match(r"^'([^']+)' depends on axioms: \[(.*)\]$", line.strip())
    m_none = re.match(r"^'([^']+)' does not depend on any axioms$", line.strip())
    if m_dep:
        thm = m_dep.group(1)
        axioms = [a.strip() for a in m_dep.group(2).split(",") if a.strip()]
        found[thm] = axioms
    elif m_none:
        found[m_none.group(1)] = []

errors = []
for thm in EXPECTED_THEOREMS:
    if thm not in found:
        errors.append(f"MISSING theorem in axiom audit output: {thm}")
        continue
    bad = [a for a in found[thm] if a not in ALLOWED]
    if bad:
        errors.append(f"FORBIDDEN AXIOM in {thm}: {bad} (allowed: {sorted(ALLOWED)})")

if "sorryAx" in text:
    errors.append("FORBIDDEN sorryAx detected in Lean output!")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

print(f"PASS: Axiom Audit verified all {len(EXPECTED_THEOREMS)} core theorems (allowed whitelist: {sorted(ALLOWED)}).")
PYEOF
