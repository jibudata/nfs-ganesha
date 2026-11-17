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

# Is <path> a mount point OF A GIVEN FILESYSTEM TYPE?
#
# is_mounted() only says "something is mounted here".  That is not enough when
# the question is "is the FUSE mount live": a plain directory that was
# bind-mounted onto itself (which is how the shared-mount trick is set up)
# is ALSO in /proc/mounts, as ext4.  Checking it that way is how a script
# comes to believe that a FUSE mount propagated out of a container when it
# did not - and then Ganesha silently drops the export and the write lands
# in the host's own filesystem.
#
#   is_fuse_mounted <path> [fstype]
is_fuse_mounted() {
  awk -v p="${1:-}" -v t="${2:-fuse.seaweedfs}" \
    '$2 == p && $3 == t { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
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

# The apparent size of a volume server's .dat files, in bytes.
#
# The APPARENT size, not the block count: the .dat files are not
# pre-truncated, so they grow with the data and the difference between
# two measurements is the number of bytes that really landed.  The
# block count would also move when the volume server compacts.
#
# This is the only way to tell "the client was told the write worked"
# from "the bytes are on the volume server".  A write that the client
# reports as successful but that never reached the .dat file is the
# failure this lab exists to catch.
vol_datsize() { # <volume-data-dir>
  find "$1" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null \
    | awk '{ s += $1 } END { printf "%d", s + 0 }'
}

# Which container scope a process lives in: host, docker or k8s.
#
# The arms of the comparison run the SAME binary with, in places, the
# SAME flags, so the command line alone does not always tell them apart.
# The cgroup does:
#
#   host    0::/system.slice/seaweedfs-master.service
#   docker  0::/system.slice/docker-<container id>.scope
#   k8s     0::/system.slice/docker-<node>.scope/kubelet.slice/.../
#           cri-containerd-<container id>.scope
#
# The k8s scope is a containerd container inside the KIND node's Docker
# container, so "is it in Docker" is not enough - the pod is one level
# deeper.
proc_scope() { # <pid>
  local cg
  cg=$(cat "/proc/$1/cgroup" 2>/dev/null)
  case "$cg" in
    *cri-containerd-*) echo k8s ;;
    *docker-*)         echo docker ;;
    *)                 echo host ;;
  esac
}

# Find the pid of a weed process whose command line contains EVERY one of
# the given needles.
#
# pids_of() excludes this script's own ancestry, so the shell that runs
# the match cannot match itself.
weed_pid_matching() { # <needle>...
  local pid cl needle all
  for pid in $(pids_of "/usr/local/bin/weed"); do
    cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    [ -n "$cl" ] || continue
    all=1
    for needle in "$@"; do
      case "$cl" in *"$needle"*) : ;; *) all=0; break ;; esac
    done
    [ "$all" -eq 1 ] && echo "$pid"
  done
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

# --- cluster space reclaim ------------------------------------------------
#
# Deleting a file through a mount deletes the filer entry and tombstones
# the chunks, but the .dat files KEEP their size: the bytes come back only
# when the master compacts the volume (vacuum).  The lab runs every master
# with -vacuumIntervalSeconds=86400 precisely so a sweep never lands inside
# a measurement (R11) - which means a harness that writes tens of GiB per
# case MUST compact on purpose, BETWEEN cases, or the disk fills by the
# third case.
#
# The HTTP route is a trap in SeaweedFS 4.x: "GET /vacuum" is answered
# with {"error":"volume id vacuum not found"} because the router reads the
# path as /<volume-id>/<command>.  The working entry point is the shell:
# weed shell refuses to run admin commands before "lock", so pipe both.
vacuum_cluster() { # <master-http-address>
  printf 'lock\nvolume.vacuum -garbageThreshold=%s\n' \
         "${VACUUM_THRESHOLD:-0.01}" \
    | timeout "${VACUUM_TIMEOUT:-300}" "${WEED_BIN:-/usr/local/bin/weed}" \
        shell -master="$1" >/dev/null 2>&1
}

# Wait until a size getter stops moving, so a measurement or a reclaim is
# not read while the number is still changing underneath it.
#
#   wait_size_stable <getter-command> <poll-secs> <max-secs>
#
# Stable means UNCHANGED for three consecutive polls.  Returns 1 when the
# maximum elapsed without stabilising (the caller decides whether that is
# fatal: a landing that never settles is, a slow vacuum is not).
wait_size_stable() { # <getter-command> <poll-secs> <max-secs>
  local get=$1 poll=$2 max=$3 waited=0 stable=0 last now
  last=$($get 2>/dev/null)
  while [ "$waited" -lt "$max" ]; do
    sleep "$poll"; waited=$((waited + poll))
    now=$($get 2>/dev/null)
    if [ "$now" = "$last" ]; then
      stable=$((stable + poll))
      [ "$stable" -ge $((poll * 3)) ] && return 0
    else
      stable=0; last=$now
    fi
  done
  return 1
}

# --- fio's completion latency, normalised to milliseconds ----------------
#
# fio picks the unit from the magnitude and prints it in the section
# header: "clat (usec):".  Stripping the header with "tr -d 'clat ():'" is
# WRONG: tr deletes every character in the set, so "clat (usec):" comes out
# as "use" and "clat (msec):" as "mse" - and a reader cannot tell msec from
# usec, or recover the unit at all.  The three-arm comparison shipped a CSV
# whose clat_unit column said "nse", "mse" and "use".
#
# Take the unit out of the parentheses and convert, so the number in the
# CSV is always milliseconds.
#
# The pod-side copy of this logic lives in k8s/run-fuse-fio.sh, which
# cannot source this file (the image does not carry it).  Keep the two in
# step.
fio_clat_ms() { # <fio output file>
  local out=$1 unit raw
  [ -f "$out" ] || { echo "0"; return 0; }
  unit=$(grep -oE 'clat \((msec|usec|nsec)\)' "$out" | head -1 | grep -oE '(msec|usec|nsec)')
  raw=$(grep -oE 'clat \((msec|usec|nsec)\):.*avg=[0-9.]+' "$out" \
        | grep -oE 'avg=[0-9.]+' | head -1 | cut -d= -f2)
  case "$unit" in
    usec) awk -v x="${raw:-0}" 'BEGIN{printf "%.3f", x/1000}' ;;
    nsec) awk -v x="${raw:-0}" 'BEGIN{printf "%.3f", x/1000000}' ;;
    *)    awk -v x="${raw:-0}" 'BEGIN{printf "%.3f", x}' ;;
  esac
}
