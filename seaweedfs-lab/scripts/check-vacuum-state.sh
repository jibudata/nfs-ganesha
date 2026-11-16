#!/bin/bash
# check-vacuum-state.sh
#
# Verify that the running lab CANNOT be interrupted by SeaweedFS's automatic
# vacuum sweep.  The linter (R11) only checks the scripts in the tree; this
# checks the system that is actually running.
#
# Three layers, all of which have to hold:
#
#   1. script   the startup script the unit executes must set
#               -vacuumIntervalSeconds >= 86400
#   2. process  the running master must carry that flag on its command line
#               (a process started before the script was edited proves
#               nothing about the script, and vice versa)
#   3. runtime  the master must have the sweep disabled by the operator
#               ("DisableVacuum (by operator)" in its log) and must not have
#               run a sweep after that
#
# A sweep rewrites whole volumes, interrupts the in-flight chunk upload
# ("multipart: NextPart: unexpected EOF" -> HTTP 400), wedges the FUSE mount,
# then the Ganesha export, then the NFS client - the export stays down for
# minutes.  See LAB-CONVENTIONS.md R11.
#
#   usage: bash check-vacuum-state.sh
set -uo pipefail

SCRIPTS_DIR=${SCRIPTS_DIR:-/home/ys1000/seaweedfs/scripts}
LOG_DIR=${LOG_DIR:-/home/ys1000/seaweedfs/logs}
MIN_INTERVAL=${MIN_INTERVAL:-86400}

RC=0
fail() { echo "  ERROR  $*"; RC=1; }
ok()   { echo "  ok     $*"; }
note() { echo "  note   $*"; }

# The effective value of -vacuumIntervalSeconds in a file: a literal, or a
# variable the same file assigns.
resolve_interval() {
  local f=$1 raw val
  raw=$(grep -oE 'vacuumIntervalSeconds=[^[:space:]\\]+' "$f" 2>/dev/null | head -1 | cut -d= -f2)
  [ -n "$raw" ] || { echo ""; return; }
  if printf '%s' "$raw" | grep -qE '^\$\{?[A-Za-z_]'; then
    local var
    var=$(printf '%s' "$raw" | sed -E 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/')
    val=$(grep -oE "^[[:space:]]*${var}=[0-9]+" "$f" 2>/dev/null | head -1 | cut -d= -f2)
  else
    val="$raw"
  fi
  echo "$val"
}

interval_ok() {
  local v=$1
  printf '%s' "$v" | grep -qE '^[0-9]+$' && [ "$v" -ge "$MIN_INTERVAL" ]
}

units=$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
        | awk '$1 ~ /seaweedfs-master/ {print $1}')

if [ -z "$units" ]; then
  echo "no seaweedfs-master* unit found (systemctl list-units)"
  exit 2
fi

echo "=== automatic vacuum sweep state ==="
echo "  minimum interval: $MIN_INTERVAL s"
echo

for unit in $units; do
  echo "--- $unit"

  # ---- 1. the startup script -------------------------------------------
  script=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null \
           | grep -oE '/[^ ;"]+\.sh' | head -1)
  if [ -z "$script" ] || [ ! -f "$script" ]; then
    fail "cannot resolve the startup script of $unit (ExecStart: $(systemctl show "$unit" -p ExecStart --value 2>/dev/null))"
  else
    sval=$(resolve_interval "$script")
    if interval_ok "$sval"; then
      ok "script $script sets -vacuumIntervalSeconds=$sval"
    else
      fail "script $script sets -vacuumIntervalSeconds=${sval:-<unset>}; it must be >= $MIN_INTERVAL"
    fi
  fi

  # ---- 2. the running process ------------------------------------------
  pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null)
  if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -r "/proc/$pid/cmdline" ]; then
    fail "$unit is not running (MainPID=${pid:-none})"
  else
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    pval=$(printf '%s' "$cmdline" | grep -oE 'vacuumIntervalSeconds=[0-9]+' | head -1 | cut -d= -f2)
    if interval_ok "$pval"; then
      ok "process $pid carries -vacuumIntervalSeconds=$pval"
    else
      fail "process $pid carries -vacuumIntervalSeconds=${pval:-<unset>}; the next restart would fall back to the 840 s default"
    fi
  fi

  # ---- 3. the runtime switch -------------------------------------------
  log=$(systemctl cat "$unit" 2>/dev/null \
        | grep -oE 'StandardOutput=append:[^[:space:]]+' | head -1 | cut -d: -f2-)
  if [ -z "$log" ] || [ ! -f "$log" ]; then
    log=$(grep -lE 'DisableVacuum \(by operator\)' "$LOG_DIR"/*.log 2>/dev/null | head -1)
  fi
  if [ -z "$log" ] || [ ! -f "$log" ]; then
    fail "cannot find the log of $unit (StandardOutput=append:<path>); cannot confirm the runtime switch"
  else
    dis_line=$(grep -an 'DisableVacuum (by operator)' "$log" | tail -1 | cut -d: -f1)
    if [ -z "$dis_line" ]; then
      fail "$log has no 'DisableVacuum (by operator)'; the automatic sweep is still armed (run: weed shell -master=... -> lock, volume.vacuum.disable, unlock)"
    else
      ok "runtime sweep disabled in $log (line $dis_line)"
      sweep_line=$(grep -an 'Start vacuuming' "$log" | tail -1 | cut -d: -f1)
      if [ -n "$sweep_line" ] && [ "$sweep_line" -gt "$dis_line" ]; then
        fail "a sweep ran AFTER the disable in $log (sweep at line $sweep_line, disable at line $dis_line); the master was probably restarted and swept immediately"
      elif [ -n "$sweep_line" ]; then
        ok "no sweep ran after the disable (last sweep at line $sweep_line)"
      else
        ok "no sweep ever ran in this log"
      fi
    fi
  fi
  echo
done

echo "result: $([ $RC -eq 0 ] && echo PASS || echo FAIL)"
exit $RC
