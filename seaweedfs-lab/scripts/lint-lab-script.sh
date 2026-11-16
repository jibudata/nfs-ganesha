#!/bin/bash
# =====================================================================
# Lint a lab script against the mechanical rules in LAB-CONVENTIONS.md.
#
#   usage: bash lint-lab-script.sh <script.sh> [more.sh ...]
#
# Every rule here corresponds to a footgun that actually cost time on
# 2026-11-16. Mechanical rules get a deterministic check, not a prose rule.
# =====================================================================
set -uo pipefail

RC=0
fail() { echo "  ERROR  $1  ($2:$3)"; RC=1; }
warn() { echo "  WARN   $1  ($2:$3)"; }
note() { echo "  note   $1  ($2:$3)"; }

check_file() {
  local f=$1
  # The linter's own source contains every banned pattern as a literal, so
  # linting it would always fail. Skip self.
  if [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ]; then
    echo "=== $f  (self, skipped)"; echo; return 0
  fi
  echo "=== $f"

  # R9 is a whole-file property: does the script bound its CPU arithmetic?
  local has_ticks=0 has_bound=0
  grep -qE 'cputicks|/proc/.*/stat.*\$14' "$f" && has_ticks=1
  grep -qE 'e\*n\)|\* *ncpu|elapsed.*ncpu|ncpu.*elapsed' "$f" && has_bound=1
  # R4 is a whole-file property too: does the harness assert landed bytes?
  local has_landed=0
  grep -qE 'landed|DATA DID NOT LAND' "$f" && has_landed=1
  # R7 is a whole-file property as well: parsing a bandwidth out of fio's
  # output must select the GROUP aggregate. fio prints one stats line per job
  # and the group summary last, so the first bw= match is job #1 and not the
  # total. Accept either the group-section format ("WRITE: bw=", uppercase,
  # which is the group summary and never matches a per-job line) or the last
  # bw= match in the file.
  local has_bwparse=0 has_groupsel=0
  grep -qE "grep[^|]*(-oE|-oe)[^|]*bw=" "$f" && has_bwparse=1
  grep -qE 'WRITE:[[:space:]]*bw=|tail[[:space:]]+-1|Run status group' "$f" && has_groupsel=1
  if [ "$has_bwparse" -eq 1 ] && [ "$has_groupsel" -eq 0 ]; then
    fail "R7 parsing a fio bandwidth must select the group aggregate (the 'WRITE: bw=' group line, or the last bw= match); the first match is job #1, not the total" "$f" 0
  fi

  # R10 is a whole-file property: restarting a FUSE mount invalidates the
  #      Ganesha export. The server holds a dirfd to the old (now detached)
  #      mount; writes through it are accepted by the kernel page cache and
  #      then lost - the client sees success, the volume server sees nothing.
  #      Any script that restarts a mount service must restart Ganesha too.
  #      A script that legitimately has no export to invalidate (it creates a
  #      brand-new cluster) opts out with a documented "r10-exempt" marker.
  local touches_mount=0 restarts_ganesha=0 r10_exempt=0
  grep -qE 'systemctl[[:space:]]+(restart|stop|start)[[:space:]]+[^ ]*seaweedfs-mount|systemctl[[:space:]]+(restart|stop|start)[[:space:]]+"\$svc"' "$f" && touches_mount=1
  grep -qE 'systemctl[[:space:]]+restart[[:space:]]+ganesha' "$f" && restarts_ganesha=1
  grep -qE 'r10-exempt' "$f" && r10_exempt=1
  if [ "$touches_mount" -eq 1 ] && [ "$restarts_ganesha" -eq 0 ] && [ "$r10_exempt" -eq 0 ]; then
    fail "R10 restarting a FUSE mount invalidates the Ganesha export (the server keeps a dirfd to the old mount and the writes are silently lost); restart ganesha as well, or mark the file 'r10-exempt' with the reason" "$f" 0
  fi

  local n=0
  while IFS= read -r line; do
    n=$((n+1))
    # strip full-line comments
    local code="${line%%#*}"
    case "$code" in *"'"*"'"*) : ;; esac

    # R1  pgrep -f / pkill -f match the invoking shell -> kills the session
    if printf '%s' "$code" | grep -qE '(^|[^a-zA-Z_-])(p?kill|pgrep)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-f'; then
      fail "R1 pgrep/pkill -f self-matches the calling shell; use -x or scan /proc/<pid>/cmdline" "$f" "$n"
    fi

    # R2  stat() on a mount point blocks in D state when the NFS client wedges
    if printf '%s' "$code" | grep -qE '(^|[^a-zA-Z_-])mountpoint([[:space:]]|$)'; then
      fail "R2 mountpoint calls stat(2); read /proc/mounts instead" "$f" "$n"
    fi
    if printf '%s' "$code" | grep -qE '(^|[[:space:]])(df|du)[[:space:]].*(/mnt/|nfs)'; then
      warn "R2 df/du on an NFS mount can block in D state" "$f" "$n"
    fi

    # R3  a synchronous umount of a wedged NFS client is unkillable. It must
    #      be BOUNDED: lazy (-l) in the background, or wrapped in a timeout.
    #      Bounding is the invariant; the two ways of bounding it are
    #      interchangeable, and backgrounding is not always available
    #      (a systemd ExecStop would have its background job killed by
    #      KillMode=control-group before the unmount could finish).
    if printf '%s' "$code" | grep -qE '(^|[[:space:]])umount[[:space:]]'; then
      if ! printf '%s' "$code" | grep -qE 'umount[[:space:]]+-l|timeout[[:space:]]+[0-9]'; then
        fail "R3 an unbounded umount can block forever on a wedged NFS client; use 'umount -l' or wrap it in 'timeout N'" "$f" "$n"
      fi
      if ! printf '%s' "$code" | grep -qE 'timeout[[:space:]]+[0-9]|[&)]|\(\s*sudo'; then
        warn "R3 umount -l must be bounded: run it in the background or wrap it in 'timeout N'" "$f" "$n"
      fi
    fi

    # R4  a case that does not verify the bytes landed reports fiction
    if printf '%s' "$code" | grep -qE '(^|[[:space:]])fio[[:space:]]'; then
      [ "$has_landed" -eq 1 ] || note "R4 this script runs fio but never asserts landed bytes (volume .dat growth)" "$f" "$n"
    fi

    # R4a  a landing probe that writes zeros false-negatives: SeaweedFS stores
    #      all-zero chunks as references, so the .dat does not grow even
    #      though the data was accepted.
    if printf '%s' "$code" | grep -qE 'if=/dev/zero'; then
      warn "R4a this script writes /dev/zero; zero chunks are stored as references, so a landing check on zero data always false-negatives" "$f" "$n"
    fi

    # R5  strace with an unavailable syscall fails silently and writes no file
    if printf '%s' "$code" | grep -qE 'strace .*-e[[:space:]]+trace='; then
      warn "R5 strace: assert the output file exists and is non-empty before interpreting it" "$f" "$n"
    fi

    # R6  prometheus must be fetched to a file; piping to wc miscounts
    if printf '%s' "$code" | grep -qE 'curl[^|]*metrics[^|]*\|[[:space:]]*(wc|head|tail)'; then
      fail "R6 fetch metrics to a file with -o, then parse it; piping miscounts" "$f" "$n"
    fi

    # R8  a case must check fio's exit code
    if printf '%s' "$code" | grep -qE '(^|[[:space:]])fio[[:space:]]+\$?\{?jf'; then
      note "R8 capture fio's rc and treat non-zero as a failed case" "$f" "$n"
    fi

    # R9  CPU accounting must be bounded by the machine's core count
    if printf '%s' "$code" | grep -qE 'cputicks|/proc/.*/stat.*\$14'; then
      [ "$has_bound" -eq 1 ] || note "R9 assert cpu_seconds <= elapsed * ncpu; a larger value means the counter arithmetic is broken" "$f" "$n"
    fi
  done < "$f"
  echo
}

if [ $# -eq 0 ]; then
  echo "usage: $0 <script.sh> [...]" >&2
  exit 2
fi

for f in "$@"; do
  [ -f "$f" ] || { echo "=== $f  (missing)"; RC=1; continue; }
  check_file "$f"
done

echo "result: $([ $RC -eq 0 ] && echo PASS || echo FAIL)"
exit $RC
