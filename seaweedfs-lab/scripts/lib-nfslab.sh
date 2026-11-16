#!/usr/bin/env bash
# =====================================================================
# Shared helpers for the lab scripts. Source it, do not execute it:
#
#   . "$(dirname "$0")/lib-nfslab.sh"
#
# Every helper here exists because the naive version of the operation
# actually cost time on 2026-11-16. See LAB-CONVENTIONS.md R1/R2/R3.
# =====================================================================

# Is <path> a mount point?
#
# Never use mountpoint(1) here: it does a stat(2) on the path, and a stat on
# a wedged NFS client blocks in uninterruptible sleep - the script hangs and
# the stat cannot be killed. /proc/mounts is a kernel table read: no I/O, no
# blocking. Field 2 is the mount point.
is_mounted() {
  awk -v p="${1:-}" '$2 == p { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

# Unmount <path> without ever blocking the caller.
#
# A synchronous umount of a wedged NFS client sits in D state and cannot be
# killed, not even with SIGKILL. A lazy unmount detaches the mount tree
# immediately; it is run in the background because even the lazy path can
# wait on a mount that is stuck in the FUSE write path. Afterwards we wait
# for the path to leave /proc/mounts, so the next mount of the same path
# does not fail with "already mounted".
lazy_unmount() {
  local p="${1:-}" i
  [ -n "$p" ] || return 0
  ( sudo umount -l "$p" >/dev/null 2>&1 ) &
  for i in $(seq 1 50); do
    is_mounted "$p" || return 0
    sleep 0.2
  done
  echo "  WARNING: $p is still in /proc/mounts after 10 s" >&2
  return 1
}

# Bounded unmount for a systemd ExecStop.
#
# Backgrounding is not an option there: systemd's default KillMode
# (control-group) kills the remaining processes of the unit as soon as
# ExecStop exits, so the unmount would never finish. A timeout bounds it
# instead, and the unit stop cannot hang.
bounded_unmount() {
  local p="${1:-}" secs="${2:-15}"
  [ -n "$p" ] || return 0
  timeout "$secs" fusermount3 -u "$p" 2>/dev/null \
    || ( timeout "$secs" sudo umount -l "$p" 2>/dev/null ) \
    || true
}

# The parent pid of <pid>, read from /proc/<pid>/stat.
#
# The comm field (field 2) is wrapped in parentheses and may itself contain
# spaces, so the fields after it cannot be addressed by number directly:
# strip everything up to the last ')' and count from there.
_ppid() {
  sed -E 's/^.*\) [A-Za-z0-9] ([0-9]+).*/\1/' "/proc/$1/stat" 2>/dev/null
}

# The pids of this process and all of its ancestors.
#
# Excluding only $$ and $PPID is not enough: the shell that runs the ssh
# command line also contains the pattern we are looking for, and it is the
# grandparent of the script. Excluding the whole chain is what makes the
# match safe.
_ancestors() {
  local p=$$
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
    echo "$p"
    p=$(_ppid "$p")
  done
}

# Find the pids whose command line contains the literal string <pattern>.
#
# pgrep -f / pkill -f match the invoking shell as well: the pattern appears
# in the ssh command line that runs the script, so the script kills its own
# session. Scan /proc/<pid>/cmdline instead and skip this process and its
# whole ancestry.
pids_of() {
  local pat="${1:-}" p pid cl ancestors
  [ -n "$pat" ] || return 0
  ancestors=" $(_ancestors | tr '\n' ' ') "
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    case "$ancestors" in *" $pid "*) continue;; esac
    # Skip our own forks: a command substitution or a pipeline component runs
    # in a subshell that inherits our command line, so it matches the pattern
    # we are looking for. A process whose parent is one of our ancestors is
    # such a fork.
    cpid=$(_ppid "$pid")
    case "$ancestors" in *" $cpid "*) continue;; esac
    [ -r "$p/cmdline" ] || continue
    cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
    [ -n "$cl" ] || continue
    case "$cl" in *"$pat"*) echo "$pid";; esac
  done
}

# Same, but <pattern> is an extended regular expression.
pids_of_re() {
  local re="${1:-}" p pid cl ancestors
  [ -n "$re" ] || return 0
  ancestors=" $(_ancestors | tr '\n' ' ') "
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    case "$ancestors" in *" $pid "*) continue;; esac
    cpid=$(_ppid "$pid")
    case "$ancestors" in *" $cpid "*) continue;; esac
    [ -r "$p/cmdline" ] || continue
    cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
    [ -n "$cl" ] || continue
    printf '%s' "$cl" | grep -qE "$re" && echo "$pid"
  done
}
