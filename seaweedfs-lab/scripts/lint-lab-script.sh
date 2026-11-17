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
# Directories whose master-script agreement has already been checked.  A plain
# string, not an associative array: /bin/bash is still 3.2 on macOS.
R11_SEEN_DIRS=""
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

  # R27 is a whole-file property: a CSV latency column must name its unit.
  #      fio picks the unit from the magnitude and prints it in the header
  #      ("clat (usec):"), so the unit has to be read out of the header and
  #      the value normalised - and the column has to say which unit it is
  #      in.  A bare "clat_avg" next to a number in an unknown unit is a
  #      unit waiting to be misread.
  local has_clat_ms=0
  grep -qE 'clat_avg_ms|clat_ms' "$f" && has_clat_ms=1
  if grep -qE 'clat_avg[,=]' "$f" && [ "$has_clat_ms" -eq 0 ]; then
    fail "R27 a CSV latency column must name its unit (clat_avg_ms); a bare 'clat_avg' next to a number in an unknown unit is a unit waiting to be misread" "$f" 0
  fi

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

  # R11 is a whole-file property: a master startup script must set the vacuum
  #      sweep interval high enough to stay out of a measurement window.  The
  #      sweep rewrites whole volumes and interrupts the in-flight chunk upload
  #      ("multipart: NextPart: unexpected EOF", HTTP 400), which wedges the
  #      FUSE mount, then the Ganesha export, then the NFS client.
  #      The value must be >= 86400 s and every master script in the same
  #      directory must agree on it: a cluster that sweeps every 14 minutes
  #      while its twin sweeps every 24 hours makes the comparison a lie.
  #      This is the rule that would have caught cluster A's master.sh, which
  #      shipped without the flag and only surfaced as a latent restart bug.
  #
  #      "Starts a master" must not be confused with "mentions a master":
  #      stop-all.sh, final-bench.sh and sustained-v2.sh all carry the string
  #      "weed master" in a pattern list or a grep, and none of them starts
  #      one.  A real master invocation is a command that also carries
  #      -mdir=, which is what the second test keys on.
  local is_master_script=0
  if grep -vE '^[[:space:]]*#' "$f" \
       | grep -qE '(^|[[:space:]"/])(weed|"\$SW_BIN")"?[[:space:]]+master([[:space:]]|$)' \
     && grep -q -- '-mdir=' "$f"; then
    is_master_script=1
  fi
  if [ "$is_master_script" -eq 1 ]; then
    local vac_raw vac_val=""
    vac_raw=$(grep -oE 'vacuumIntervalSeconds=[^[:space:]\\]+' "$f" | head -1 | cut -d= -f2)
    if printf '%s' "$vac_raw" | grep -qE '^\$\{?[A-Za-z_]'; then
      # a generator may defer to a variable; resolve it inside the same file
      local vac_var
      vac_var=$(printf '%s' "$vac_raw" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/')
      vac_val=$(grep -oE "^[[:space:]]*${vac_var}=[0-9]+" "$f" | head -1 | cut -d= -f2)
    else
      vac_val="$vac_raw"
    fi
    if [ -z "$vac_val" ]; then
      fail "R11 this script starts a SeaweedFS master but never sets -vacuumIntervalSeconds; the 840 s default sweep can interrupt a chunk upload and wedge the export" "$f" 0
    elif ! printf '%s' "$vac_val" | grep -qE '^[0-9]+$'; then
      fail "R11 -vacuumIntervalSeconds must be a plain number of seconds, got '$vac_val'" "$f" 0
    elif [ "$vac_val" -lt 86400 ]; then
      fail "R11 -vacuumIntervalSeconds=$vac_val is below 86400 s; the sweep would run inside the measurement window" "$f" 0
    fi
    # cross-file agreement, once per directory
    local mdir
    mdir=$(cd "$(dirname "$f")" && pwd)
    case " $R11_SEEN_DIRS " in
      *" $mdir "*) : ;;
      *)
        R11_SEEN_DIRS="$R11_SEEN_DIRS $mdir"
        local sib sval
        for sib in "$mdir"/master*.sh; do
          [ -f "$sib" ] || continue
          sval=$(grep -oE 'vacuumIntervalSeconds=[0-9]+' "$sib" | head -1 | cut -d= -f2)
          if [ -z "$sval" ]; then
            fail "R11 sibling master script $(basename "$sib") does not set -vacuumIntervalSeconds; a cluster created without it comes up with the 14-minute default" "$f" 0
          elif [ -n "$vac_val" ] && [ "$sval" != "$vac_val" ]; then
            fail "R11 master scripts disagree on -vacuumIntervalSeconds ($sib has $sval, this file has $vac_val); the two tiers would not be comparable" "$f" 0
          fi
        done
        ;;
    esac
  fi

  local n=0
  local prev_continued=0
  while IFS= read -r line; do
    n=$((n+1))

    # R12  a comment line inside a backslash-continued command TRUNCATES it:
    #      the backslash joins the next physical line into the command, and a
    #      '#' there starts a comment that ends at the newline, so the rest of
    #      the command is executed as a separate statement.  Verified:
    #        printf '%s\n' a \
    #          # comment
    #          b        # <- runs "b" as its own command
    #      bash -n does not catch it, because the result is still valid syntax.
    #
    #      A comment line that ENDS with a backslash is not a continuation:
    #      inside a comment the backslash is literal and the comment ends at
    #      the newline.  Only a CODE line can continue into the next one.
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    if [ "$prev_continued" -eq 1 ]; then
      case "$trimmed" in
        '#'*) fail "R12 a comment inside a backslash-continued command truncates it (the next line becomes a separate command); move the comment above the command" "$f" "$n" ;;
      esac
    fi
    prev_continued=0
    case "$trimmed" in
      '#'*) : ;;
      *) case "$line" in *\\) prev_continued=1 ;; esac ;;
    esac

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

    # R27  a unit must not be recovered by DELETING characters: tr -d
    #      removes every character in the set, so "clat (usec):" minus
    #      "clat ():" is "use", not "usec".  Take the unit out of the
    #      parentheses instead (fio_clat_ms in lib-nfslab.sh does).
    if printf '%s' "$code" | grep -qE 'tr[[:space:]]+-d[^|]*(clat|msec|usec|nsec)'; then
      fail "R27 do not strip a unit out of fio's output by deleting characters (tr -d 'clat ():' turns 'usec' into 'use'); take the unit out of the parentheses and normalise it" "$f" "$n"
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
