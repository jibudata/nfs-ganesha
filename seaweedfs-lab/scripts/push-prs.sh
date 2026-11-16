#!/bin/bash
# =====================================================================
# Push the two prepared branches to the fork and open the pull requests.
#
#   bash push-prs.sh            # push both branches and create both PRs
#   bash push-prs.sh --push-only # push the branches, do not open the PRs
#
# Needs: git with SSH access to the fork, and the gh CLI authenticated
# for that account (gh auth status).
# =====================================================================
set -uo pipefail

REPO=${REPO:-/Users/gyj/code/github/nfs-ganesha/nfs-ganesha}
PRDIR=${PRDIR:-/Users/gyj/code/github/nfs-ganesha/seaweedfs-lab/pr}
REMOTE=origin
BASE=next

PUSH_ONLY=0
[ "${1:-}" = "--push-only" ] && PUSH_ONLY=1

cd "$REPO" || exit 1

echo "=== remote ==="
git remote -v
echo

BRANCHES=(
  "fix/dynamic-metrics-null-deref"
  "ci/github-actions-build-and-format"
)
BODIES=(
  "$PRDIR/0001-null-deref.md"
  "$PRDIR/0002-ci-build-and-format.md"
)
TITLES=(
  "monitoring: fix NULL deref in dynamic_metrics_export_info()"
  "ci: add a GitHub Actions build and format check"
)

echo "=== pushing the branches ==="
for b in "${BRANCHES[@]}"; do
  echo "--- $b"
  git push -u "$REMOTE" "$b" || { echo "push failed for $b"; exit 1; }
done
echo

if [ "$PUSH_ONLY" -eq 1 ]; then
  echo "branches pushed; not opening the pull requests (--push-only)"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "the gh CLI is not installed"; exit 1; }

echo "=== opening the pull requests against $BASE ==="
for i in "${!BRANCHES[@]}"; do
  b=${BRANCHES[$i]}
  echo "--- $b"
  # A pull request that already exists for this head branch is updated, not
  # duplicated: re-running this script must be safe.
  existing=$(gh pr list --repo jibudata/nfs-ganesha --head "$b" --state open \
    --json number --jq '.[0].number' 2>/dev/null)
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "pull request #$existing already exists, updating it"
    gh pr edit "$existing" \
      --repo jibudata/nfs-ganesha \
      --title "${TITLES[$i]}" \
      --body-file "${BODIES[$i]}"
  else
    gh pr create \
      --repo jibudata/nfs-ganesha \
      --base "$BASE" \
      --head "$b" \
      --title "${TITLES[$i]}" \
      --body-file "${BODIES[$i]}"
  fi
done
echo
echo "done"
