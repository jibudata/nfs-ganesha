# SeaweedFS for the containerised arm of the comparison.
#
# The binary is COPIED from the lab host instead of pulled from a registry.
# That is the whole point: the containerised backend is then the EXACT same
# build as the bare-metal one (4.54, commit 5ef99c1d, statically linked), so
# the only variable between the two arms of the comparison is the packaging
# - never the storage engine's version, its build flags or its Go runtime.
#
# A registry image would silently move the version and make every number
# meaningless.
#
# The binary is statically linked (checked with `file`/`ldd`), so it needs no
# Go runtime and no shared libraries; only the FUSE helper is installed.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse3 ca-certificates \
 && apt-get clean \
 && find /var/lib/apt/lists -mindepth 1 -delete

COPY weed /usr/local/bin/weed
COPY entrypoint.sh /work/entrypoint.sh
RUN chmod +x /usr/local/bin/weed /work/entrypoint.sh \
 && weed version

# `weed mount` needs the FUSE device and CAP_SYS_ADMIN; both come from
# --device /dev/fuse and --privileged at run time.
ENV SW_BIN=/usr/local/bin/weed
WORKDIR /work
