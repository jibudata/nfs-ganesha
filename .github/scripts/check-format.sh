#!/bin/bash
# =====================================================================
# Check that the lines this branch changed are formatted according to
# .clang-format.
#
# Only the CHANGED lines are checked. The tree already carries
# pre-existing clang-format violations, so a whole-file check would be red
# before any change is made and would drown the signal. Checking the diff
# keeps the job meaningful: it fails on what this branch introduced.
#
# Environment:
#   CLANG_FORMAT   path to the formatter (default: clang-format)
#   GITHUB_BASE_REF  base branch of a pull request (optional)
# =====================================================================
set -uo pipefail

CF=${CLANG_FORMAT:-clang-format}
IGNORE_FILE=.clang-format-ignore

command -v "$CF" >/dev/null 2>&1 || { echo "::error::$CF not found"; exit 1; }

base=""
if [ -n "${GITHUB_BASE_REF:-}" ]; then
  git fetch -q origin "$GITHUB_BASE_REF" 2>/dev/null || true
  if git rev-parse -q --verify "origin/$GITHUB_BASE_REF" >/dev/null 2>&1; then
    base="origin/$GITHUB_BASE_REF"
  fi
fi
if [ -z "$base" ]; then
  base=$(git rev-parse HEAD~1 2>/dev/null || true)
fi
if [ -z "$base" ]; then
  echo "no base ref to compare against; nothing to check"
  exit 0
fi

echo "checking the formatting of the lines changed against $base"

# Only C and C++ sources are formatted by clang-format; feeding it a shell
# script or a YAML file produces meaningless violations.
#
# file -> comma separated line ranges in the NEW file
ranges=$(git diff -U0 "$base" HEAD -- \
    '*.c' '*.h' '*.cc' '*.cpp' '*.cxx' '*.hpp' '*.hh' | awk '
    /^diff --git / { file = $4; sub(/^b\//, "", file); next }
    /^@@/ {
        n = split($0, parts, " ")
        split(parts[3], r, ",")
        start = r[1] + 0
        count = (r[2] == "" ? 1 : r[2] + 0)
        if (count > 0) {
            if (file in R) R[file] = R[file] "," (start ":" (start + count - 1))
            else           R[file] = (start ":" (start + count - 1))
        }
    }
    END { for (f in R) print f "\t" R[f] }
')

rc=0
checked=0
while IFS=$'\t' read -r file range_list; do
    [ -z "${file:-}" ] && continue
    [ -f "$file" ] || continue
    if [ -f "$IGNORE_FILE" ] && grep -qxF "$file" "$IGNORE_FILE"; then
        echo "skipping $file (listed in $IGNORE_FILE)"
        continue
    fi

    args=()
    IFS=',' read -ra ranges <<< "$range_list"
    for r in "${ranges[@]}"; do
        [ -n "$r" ] && args+=("--lines=$r")
    done
    [ ${#args[@]} -eq 0 ] && continue

    out=$("$CF" --dry-run --Werror "${args[@]}" "$file" 2>&1)
    if [ -n "$out" ]; then
        echo "::error file=$file::clang-format violations in the lines this branch changed"
        echo "$out"
        rc=1
    fi
    checked=$((checked+1))
done <<< "$ranges"

if [ $rc -eq 0 ]; then
    echo "clang-format: $checked file(s) checked, the changed lines are clean"
fi
exit $rc
