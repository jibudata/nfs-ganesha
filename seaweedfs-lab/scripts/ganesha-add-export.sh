#!/bin/bash
# =====================================================================
# ganesha-add-export.sh <pseudo> <path>
#
# Add an export to /etc/ganesha/ganesha.conf and restart Ganesha so it
# picks it up.  Hand-editing the config is how the delivery copy and the
# live one drift apart; a script keeps the change reproducible and makes
# the restart part of the same step.
#
#   usage: bash ganesha-add-export.sh /seaweedfs-docker \
#                            /home/ys1000/seaweedfs/mnt-docker
#
# The export block is the same shape as the existing ones (VFS, Root_Squash,
# 1 MiB r/w).  The Export_Id is the next free one.
#
# Restarting Ganesha drops every client mount, so do it when nothing is
# measuring.  And remember the rule this lab learned the hard way: the
# export's Path must already be a live FUSE mount when Ganesha starts, or
# Ganesha silently drops the export (LAB-CONVENTIONS.md R10).
# =====================================================================
set -uo pipefail

PSEUDO=${1:?usage: ganesha-add-export.sh <pseudo> <path>}
PATH_=${2:?usage: ganesha-add-export.sh <pseudo> <path>}
CONF=${GANESHA_CONF:-/etc/ganesha/ganesha.conf}

if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF is not there" >&2
  exit 2
fi

if sudo grep -q "Pseudo = \"$PSEUDO\"" "$CONF"; then
  echo "=== $PSEUDO is already exported; nothing to do ==="
  exit 0
fi

# the next free Export_Id
max_id=$(sudo grep -oE 'Export_Id = [0-9]+' "$CONF" | grep -oE '[0-9]+' | sort -n | tail -1)
new_id=$(( ${max_id:-0} + 1 ))

echo "=== adding the export $PSEUDO -> $PATH_ (Export_Id $new_id) ==="

backup="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
sudo cp "$CONF" "$backup"
echo "  backup: $backup"

block=$(cat <<EOF

# Containerised arm of the comparison: the same SeaweedFS (same 4.54
# binary) running in Docker, with its FUSE mount propagated onto the host
# so that Ganesha can export it.
EXPORT {
    Export_Id = $new_id;
    Path = "$PATH_";
    Pseudo = "$PSEUDO";

    Access_Type = RW;
    Squash = Root_Squash;
    Protocols = 4, 3;
    Transports = TCP;
    SecType = sys, none;

    MaxWrite = 1048576;
    MaxRead  = 1048576;
    PrefWrite = 1048576;
    PrefRead  = 1048576;
    PrefReaddir = 1048576;

    FSAL {
        Name = VFS;
    }
}
EOF
)

printf '%s\n' "$block" | sudo tee -a "$CONF" > /dev/null
echo "  appended to $CONF"

# The export's Path has to be a live mount before Ganesha resolves it.
if ! awk -v p="$PATH_" '$2 == p { found = 1 } END { exit !found }' /proc/mounts; then
  echo "WARNING: $PATH_ is not in /proc/mounts - Ganesha will silently drop this export." >&2
  echo "         Start the backend first, then add the export." >&2
fi

echo "--- restarting Ganesha"
sudo systemctl restart ganesha
sleep 3
systemctl is-active ganesha

echo "--- the export in the log"
sudo journalctl -u ganesha --since "-1 min" --no-pager 2>/dev/null \
  | grep -iE "$PSEUDO|export" | tail -5 || true
echo "done"
