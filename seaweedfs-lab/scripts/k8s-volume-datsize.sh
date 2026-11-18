#!/bin/bash
# =====================================================================
# k8s-volume-datsize.sh
#
# Print the total apparent size of the Kubernetes arm's .dat files, in
# bytes.
#
#   usage: bash k8s-volume-datsize.sh
#
# WHY IT LOOKS INTO THE POD INSTEAD OF AT A HOST PATH
#
# The local-path provisioner creates the PersistentVolume as a hostPath
# on the NODE.  The node is not necessarily the machine this script runs
# on: a KIND cluster runs its node as a Docker container, and then the
# hostPath does not exist on the host at all.  A landing check that
# looks for that path finds nothing, reports "no bytes landed", and
# concludes that the write was lost - a false negative, and the exact
# failure this lab exists to avoid.  The pod sees the data wherever the
# node lives, so the measurement is taken from inside the pod.
#
# WHAT IS MEASURED
#
# The APPARENT size, the same way the bare-metal and the Docker arms
# measure it (find -printf '%s').  The .dat files are not pre-truncated,
# so the apparent size grows with the data and the difference between two
# measurements is the number of bytes that really landed.  A zero delta
# means the write did not reach the volume server - whatever the client
# was told.
#
# The data has to be NON-ZERO for the delta to move: SeaweedFS stores an
# all-zero chunk as a reference only.  The probe writes /dev/urandom.
# See LAB-CONVENTIONS.md R4/R4a.
# =====================================================================
set -uo pipefail

KUBECTL=${KUBECTL:-kubectl}
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for c in "$HOME/.local/bin/kubectl" /usr/local/bin/kubectl /usr/bin/kubectl; do
    if [ -x "$c" ]; then KUBECTL=$c; break; fi
  done
fi
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

NS=${K8S_NS:-seaweedfs}
POD=${K8S_VOLUME_POD:-seaweedfs-volume-0}
DIR=${K8S_VOLUME_DIR:-/data/vol}

out=$("$KUBECTL" -n "$NS" exec "$POD" -- \
        find "$DIR" -maxdepth 3 -name '*.dat' -printf '%s\n' 2>/dev/null)
# %.0f, not %d: mawk (the default awk on ubuntu runners) truncates %d to
# 32 bits, so any total over 2GiB wraps; a double is exact to 2^53.
printf '%s\n' "$out" | awk '{ s += $1 } END { printf "%.0f", s + 0 }'
