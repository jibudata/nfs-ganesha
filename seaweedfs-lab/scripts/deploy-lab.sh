#!/bin/bash
# =====================================================================
# deploy-lab.sh [host] [remote-root]
#
# Copy the lab tree onto the lab host and VERIFY it.  Hand-copying
# individual files is how the tree drifts: on 2026-11-16 the masters ran
# with -vacuumIntervalSeconds=86400 while the startup script the systemd
# unit actually executes did not contain it, and nothing noticed until
# someone read the script.  One command, one verification.
#
#   usage: bash deploy-lab.sh [ys1000@192.168.3.146] [/home/ys1000/seaweedfs]
#
# What goes over
#   scripts/                     the operational scripts, the systemd units
#                                and seaweedfs.env
#   README.md          -> scripts/README.md
#   ganesha.conf       -> scripts/ganesha.conf
#   ganesha.service    -> scripts/ganesha.service
#   LAB-CONVENTIONS.md, RETRO.md -> the lab root
#
# What stays behind
#   scripts/sync-to-repo.sh       a workspace->repository tool; the host has
#                                 no repository next to it, so it is meaningless
#                                 there
#   scripts/ganesha-seaweedfs.conf
#                                 an unreferenced leftover from the V15.12
#                                 era.  It is preserved and reported, never
#                                 deleted - deciding what to throw away is
#                                 the operator's call, not a deploy's.
#
# Nothing is deleted blindly.  A script that exists on the host but not in
# this tree is a hand-written script: the deploy stops and says so instead
# of removing it.  (17 such scripts were found on the lab host on
# 2026-11-16 - they belonged in the tree and are now in it.)
# =====================================================================
set -euo pipefail

HOST=${1:-ys1000@192.168.3.146}
REMOTE_ROOT=${2:-/home/ys1000/seaweedfs}

SRC=$(cd "$(dirname "$0")/.." && pwd)
REPO_ONLY="sync-to-repo.sh"
HOST_ONLY="ganesha-seaweedfs.conf"

echo "=== deploy lab ==="
echo "  source:      $SRC"
echo "  host:        $HOST"
echo "  remote root: $REMOTE_ROOT"
echo

for required in scripts README.md ganesha.conf ganesha.service LAB-CONVENTIONS.md RETRO.md; do
  if [ ! -e "$SRC/$required" ]; then
    echo "ERROR: $SRC/$required is missing; run this from the lab tree" >&2
    exit 2
  fi
done

# ---- 0. what is on the host that this tree does not know about? --------
echo "--- inspect the host"
# newline -> space: the membership test below matches on space-delimited words
host_scripts=$(ssh "$HOST" "cd $REMOTE_ROOT/scripts && ls -1 *.sh 2>/dev/null | LC_ALL=C sort" | tr '\n' ' ')
source_scripts=$(cd "$SRC/scripts" && ls -1 *.sh | LC_ALL=C sort | tr '\n' ' ')

unknown=""
for f in $host_scripts; do
  case " $source_scripts " in
    *" $f "*) : ;;
    *) unknown="$unknown $f" ;;
  esac
done
if [ -n "$unknown" ]; then
  echo "ERROR: the host has scripts this tree does not have:" >&2
  for f in $unknown; do echo "         $f" >&2; done
  echo "       Add them to the tree, or remove them deliberately." >&2
  echo "       (A deploy must not delete a script it did not write.)" >&2
  exit 1
fi

host_extras=$(ssh "$HOST" "cd $REMOTE_ROOT/scripts && ls -1A 2>/dev/null | LC_ALL=C sort")
for f in $host_extras; do
  if [ ! -e "$SRC/scripts/$f" ] && [ ! -e "$SRC/$f" ]; then
    case " $HOST_ONLY " in
      *" $f "*) echo "  note   preserving host-only file $f" ;;
      *) echo "ERROR: the host has $f, which this tree does not know about." >&2
         echo "       Add it to the tree, or list it in HOST_ONLY." >&2
         exit 1 ;;
    esac
  fi
done

# ---- 1. scripts, units and env ----------------------------------------
echo "--- scripts"
rsync -a --delete \
      --exclude "$REPO_ONLY" \
      --exclude "$HOST_ONLY" \
      --exclude 'README.md' \
      --exclude 'ganesha.conf' \
      --exclude 'ganesha.service' \
      "$SRC/scripts/" "$HOST:$REMOTE_ROOT/scripts/"

# ---- 2. the files that live at the tree root ---------------------------
echo "--- host-side copies of the tree root"
rsync -a "$SRC/README.md" "$SRC/ganesha.conf" "$SRC/ganesha.service" \
      "$HOST:$REMOTE_ROOT/scripts/"

echo "--- documents"
rsync -a "$SRC/LAB-CONVENTIONS.md" "$SRC/RETRO.md" \
      "$HOST:$REMOTE_ROOT/"

# ---- 2b. the container / kubernetes artefacts --------------------------
# The docker/ and k8s/ trees hold the containerised arms of the comparison.
for dir in docker k8s; do
  if [ -d "$SRC/$dir" ]; then
    echo "--- $dir"
    rsync -a --delete "$SRC/$dir/" "$HOST:$REMOTE_ROOT/$dir/"
  fi
done

# ---- 3. make the scripts executable ------------------------------------
echo "--- permissions"
ssh "$HOST" "chmod +x $REMOTE_ROOT/scripts/*.sh $REMOTE_ROOT/docker/*.sh 2>/dev/null; true"

# ---- 4. verify: every script on the host matches this tree ------------
echo "--- verify: every script on the host matches this tree"
# Fixed paths, overwritten on every run, and deliberately NOT deleted at the
# end: "rm" in a script is intercepted by the desktop's delete guard, which
# turns it into a recoverable-trash call that waits for a confirmation this
# non-interactive run can never give.
local_list="${TMPDIR:-/tmp}/nfslab-deploy-local.md5"
remote_list="${TMPDIR:-/tmp}/nfslab-deploy-remote.md5"

( cd "$SRC/scripts" && md5sum *.sh | grep -v " $REPO_ONLY\$" | LC_ALL=C sort ) > "$local_list"
ssh "$HOST" "cd $REMOTE_ROOT/scripts && md5sum *.sh | LC_ALL=C sort" > "$remote_list"

if diff "$local_list" "$remote_list" > /dev/null; then
  echo "  ok     $(wc -l < "$local_list" | tr -d ' ') scripts byte-identical"
else
  echo "  ERROR  the host's scripts differ from this tree:" >&2
  diff "$local_list" "$remote_list" >&2
  exit 1
fi

echo "--- verify: the host-side copies of the tree root"
for f in README.md ganesha.conf ganesha.service; do
  a=$(md5sum "$SRC/$f" | cut -d' ' -f1)
  b=$(ssh "$HOST" "md5sum $REMOTE_ROOT/scripts/$f | cut -d' ' -f1")
  if [ "$a" = "$b" ]; then
    echo "  ok     $f"
  else
    echo "  ERROR  $f differs (tree $a, host $b)" >&2
  fi
done

# ---- 5. the host's own linter must agree ------------------------------
echo "--- verify: the host's linter agrees"
ssh "$HOST" "cd $REMOTE_ROOT/scripts && bash lint-lab-script.sh *.sh ../docker/*.sh" | tail -1

# ---- 6. and the running system must be safe to measure -----------------
echo "--- verify: the running lab is not exposed to a vacuum sweep"
ssh "$HOST" "bash $REMOTE_ROOT/scripts/check-vacuum-state.sh" | tail -1

echo
echo "deploy done"
