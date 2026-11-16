#!/bin/bash
# =====================================================================
# Copy the lab tree from the workspace copy into the nfs-ganesha
# repository, where it lives on the fork's v15.9 branch and can be
# committed and pushed.
#
#   bash seaweedfs-lab/scripts/sync-to-repo.sh
#
# The workspace copy (../seaweedfs-lab next to the repo) is where the lab
# is edited; the repository copy is what gets published. This script is
# the one step between them.
#
# Environment:
#   SRC    the workspace copy     (default: <workspace>/seaweedfs-lab)
#   REPO   the nfs-ganesha clone  (default: <workspace>/nfs-ganesha)
#   BRANCH the branch to sync onto (default: v15.9)
# =====================================================================
set -uo pipefail

WS=${WS:-/Users/gyj/code/github/nfs-ganesha}
SRC=${SRC:-$WS/seaweedfs-lab}
REPO=${REPO:-$WS/nfs-ganesha}
DEST=$REPO/seaweedfs-lab
BRANCH=${BRANCH:-v15.9}

[ -d "$SRC" ] || { echo "no such source dir: $SRC" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "not a git clone: $REPO" >&2; exit 1; }

echo "=== source: $SRC"
echo "=== dest:   $DEST"
echo "=== branch: $BRANCH"

cd "$REPO" || exit 1
current=$(git rev-parse --abbrev-ref HEAD)
if [ "$current" != "$BRANCH" ]; then
  echo "--- switching to $BRANCH"
  git checkout "$BRANCH" || exit 1
fi

mkdir -p "$DEST"
if command -v rsync >/dev/null 2>&1; then
  # --delete keeps the repository copy free of files that were removed in
  # the workspace copy; without it the two copies drift apart.
  rsync -a --delete "$SRC/" "$DEST/" || exit 1
else
  echo "rsync not found, falling back to cp (stale files will linger)"
  cp -R "$SRC/." "$DEST/" || exit 1
fi

echo
echo "=== what changed in the repository ==="
git status --porcelain seaweedfs-lab | head -40
n=$(git status --porcelain seaweedfs-lab | wc -l | tr -d ' ')
echo "  ($n changed path(s))"

echo
echo "=== lint the tree that was just synced ==="
if [ -x "$DEST/scripts/lint-lab-script.sh" ] || [ -f "$DEST/scripts/lint-lab-script.sh" ]; then
  bash "$DEST/scripts/lint-lab-script.sh" "$DEST"/scripts/*.sh 2>&1 | tail -3
fi

echo
echo "next: review the diff, then commit and push"
echo "  git -C $REPO add seaweedfs-lab && git -C $REPO commit -s -m '...'"
echo "  git -C $REPO push origin $BRANCH"
