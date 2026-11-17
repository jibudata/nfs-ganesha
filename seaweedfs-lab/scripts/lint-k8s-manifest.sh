#!/bin/bash
# =====================================================================
# lint-k8s-manifest.sh - lint the Kubernetes arm's manifests.
#
#   usage: bash lint-k8s-manifest.sh <manifest.yaml> [more.yaml ...]
#
# Every rule here corresponds to a failure mode that this arm actually
# has, not a hypothetical one.
#
#   R19  A manifest that starts a master must set -vacuumIntervalSeconds
#        high enough to stay out of a measurement window.  The same
#        reason as R11: the sweep rewrites whole volumes and interrupts
#        the in-flight chunk upload, which wedges the FUSE mount, then
#        the Ganesha export, then the NFS client.
#
#   R20  The address the process REGISTERS and the address the
#        LoadBalancer hands out must be the SAME address.  SeaweedFS
#        advertises `-ip`, and that is the address the host's FUSE mount
#        fetches chunks from (weed/filer/reader_at.go:123 ->
#        dn.Url() -> <the volume's -ip>:<port>).  A workload that
#        advertises the pod IP while the Service hands out a different
#        address is a workload the host cannot reach, and the failure
#        looks like a slow disk.
#
#   R21  The gRPC port must be the HTTP port plus 10000, on both sides:
#        in the container's arguments and in the Service's ports.  A
#        client given the HTTP port dials http+10000 for gRPC, and a
#        Service that publishes only the HTTP port refuses it.
#
#   R22  A LoadBalancer Service must have a FIXED address.  An
#        auto-assigned one cannot be advertised by a pod, because the
#        pod's `-ip` has to be known when the manifest is written.
# =====================================================================
set -uo pipefail

RC=0
fail() { echo "  ERROR  $1  ($2)"; RC=1; }

check_file() {
  local f=$1
  echo "=== $f"

  # ---- R19: the master's vacuum sweep ------------------------------
  # "starts a master" = the weed binary with "master" as the
  # sub-command.  A manifest that only mentions a master is not one.
  if grep -qE '^[[:space:]]*-[[:space:]]+/usr/local/bin/weed[[:space:]]*$' "$f" \
     && grep -A1 -E '^[[:space:]]*-[[:space:]]+/usr/local/bin/weed[[:space:]]*$' "$f" \
          | grep -qE '^[[:space:]]*-[[:space:]]+master[[:space:]]*$'; then
    local vac
    vac=$(grep -oE '\-vacuumIntervalSeconds=[0-9]+' "$f" | head -1 | cut -d= -f2)
    if [ -z "$vac" ]; then
      fail "R19 this manifest starts a SeaweedFS master but never sets -vacuumIntervalSeconds; the 840 s default sweep can interrupt a chunk upload and wedge the export" "$f"
    elif [ "$vac" -lt 86400 ]; then
      fail "R19 -vacuumIntervalSeconds=$vac is below 86400 s; the sweep would run inside the measurement window" "$f"
    fi
  fi

  # ---- R20: the advertised address is the routable address --------
  local adv
  adv=$(grep -oE '^[[:space:]]*-[[:space:]]+-ip=[0-9.]+[[:space:]]*$' "$f" | head -1 | sed -E 's/.*-ip=([0-9.]+).*/\1/')
  if [ -n "$adv" ]; then
    if ! grep -qE "^[[:space:]]*loadBalancerIP:[[:space:]]*${adv}[[:space:]]*$" "$f"; then
      fail "R20 the workload advertises -ip=$adv, but no LoadBalancer Service hands out that address; the host's FUSE mount would fetch chunks from an address it cannot route" "$f"
    fi
  fi

  # ---- R21: grpc = http + 10000, on both sides ---------------------
  local http grpc
  for http in $(grep -oE '\-volume\.port=[0-9]+' "$f" | cut -d= -f2 | sort -u); do
    grpc=$(grep -oE '\-volume\.port\.grpc=[0-9]+' "$f" | cut -d= -f2 | head -1)
    if [ -z "$grpc" ]; then
      fail "R21 the volume server listens on $http but publishes no gRPC port; gRPC = http + 10000 = $((http+10000))" "$f"
    elif [ "$grpc" != "$((http+10000))" ]; then
      fail "R21 the volume server's gRPC port is $grpc, but it must be $((http+10000)) (gRPC = http + 10000)" "$f"
    fi
  done
  for http in $(grep -oE '(^|[[:space:]])-port=[0-9]+' "$f" | grep -oE '[0-9]+$' | sort -u); do
    grpc=$(grep -oE '\-port\.grpc=[0-9]+' "$f" | cut -d= -f2 | head -1)
    if [ -z "$grpc" ]; then
      fail "R21 the service listens on $http but publishes no gRPC port; gRPC = http + 10000 = $((http+10000))" "$f"
    elif [ "$grpc" != "$((http+10000))" ]; then
      fail "R21 the service's gRPC port is $grpc, but it must be $((http+10000)) (gRPC = http + 10000)" "$f"
    fi
  done

  # A LoadBalancer Service must publish both ports.
  if grep -qE '^[[:space:]]*type:[[:space:]]*LoadBalancer[[:space:]]*$' "$f"; then
    if ! grep -qE '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*grpc[[:space:]]*$' "$f"; then
      fail "R21 the LoadBalancer Service publishes no gRPC port; a client given the HTTP port dials http + 10000 and gets refused" "$f"
    fi
    if ! grep -qE '^[[:space:]]*loadBalancerIP:[[:space:]]*[0-9.]+[[:space:]]*$' "$f"; then
      fail "R22 the LoadBalancer Service has no fixed address; the pod's -ip has to be known when the manifest is written" "$f"
    fi
  fi
}

if [ $# -eq 0 ]; then
  echo "usage: $0 <manifest.yaml> ..." >&2
  exit 2
fi

for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f is not there" >&2
    exit 2
  fi
  check_file "$f"
done

if [ "$RC" = "0" ]; then
  echo "result: PASS"
else
  echo "result: FAIL"
fi
exit "$RC"
