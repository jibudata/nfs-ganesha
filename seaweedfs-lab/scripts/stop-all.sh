#!/usr/bin/env bash
# Stop the whole SeaweedFS stack in the right order (mount -> filer -> volume -> master)
set -uo pipefail
. /home/ys1000/seaweedfs/scripts/seaweedfs.env
# Shared helpers: is_mounted / bounded_unmount / pids_of. See LAB-CONVENTIONS.md R1/R2/R3.
. "$(dirname "$0")/lib-nfslab.sh"

echo "--- unmounting $SW_MNT ---"
if is_mounted "$SW_MNT"; then
  bounded_unmount "$SW_MNT" 15
fi

for pat in "weed mount" "weed filer" "weed server" "weed master"; do
  pids=$(pids_of "$pat")
  if [ -n "$pids" ]; then
    echo "--- stopping: $pat ($pids) ---"
    kill $pids 2>/dev/null || true
  fi
done

sleep 3
for pat in "weed mount" "weed filer" "weed server" "weed master"; do
  pids=$(pids_of "$pat")
  [ -n "$pids" ] && { echo "--- force kill: $pat ---"; kill -9 $pids 2>/dev/null || true; }
done
echo "done."
