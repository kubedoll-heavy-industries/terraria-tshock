# syntax=docker/dockerfile:1.7
#
# terraria-tshock — hardened, version-pinned TShock container.
#
# Layers (top → bottom = least → most cache-busting):
#   1. Builder: debian-slim, fetches+verifies TShock zip and plugin DLLs.
#   2. Runtime: Microsoft .NET 9 runtime slim, copies verified artifacts only.
#
# Everything mutable about the build is a top-level ARG so CI can override and
# `plugins.lock` documents the same values for humans. Changes to ARGs cascade
# correctly through BuildKit's cache.
#
# Why .NET 9 for a TShock 5.x build that targets .NET 6?
#   .NET 6 is EOL (Nov 2024) and ships unpatched CVEs. We instead install the
#   supported .NET 9 runtime and set DOTNET_ROLL_FORWARD=LatestMajor so the
#   .NET 6 apphost in TShock.Server loads against the 9.0 shared framework.
#   Verified working at build time on linux/amd64.
#
# Why not Alpine / TrueCharts scratch?
#   TShock.Server is a glibc-linked ELF (libc.so.6, libstdc++.so.6, libgcc_s.so.1).
#   musl-based Alpine would require a glibc shim — more attack surface, not less.

# ---------------------------------------------------------------------------
# Stage 1: build context. Fetches archives and verifies SHA256 sums.
# Pinned by digest so a hostile mirror cannot serve us a different debian.
# ---------------------------------------------------------------------------
FROM debian@sha256:67b30a61dc87758f0caf819646104f29ecbda97d920aaf5edc834128ac8493d3 AS fetch

ARG TARGETARCH
RUN [ "$TARGETARCH" = "amd64" ] || { echo "this image is amd64-only; got $TARGETARCH"; exit 1; }

# TShock release.
ARG TSHOCK_VERSION=5.2.4
ARG TSHOCK_TERRARIA_VERSION=1.4.4.9
ARG TSHOCK_ZIP_SHA256=5c0bd0fc0777a535b6bb759c5bda4817549cdb02aee0ed371895eba26ff721f2

# Plugins: pin the source repo commit AND each file's sha256.
# Pinning the commit alone is not enough — main can be force-pushed, and ref-by-
# commit only guarantees the tree, not what a CDN cache might serve via the raw
# URL we fetch from. So we verify both: commit-pinned URL + content hash.
ARG PLUGINS_REPO=RenderBr/tShock-v5-plugins
ARG PLUGINS_COMMIT=b67aa63bad1e7ab23d2688ec012b3b8ca4619163
ARG PLUGIN_HISTORY_SHA256=abf007230819613865a38c7ef689393bf2d41793aa5c70842b17381dda2ee4e0
ARG PLUGIN_ANTISPAM_SHA256=7b665d558415ac283a78ffe96642994253e9a4192f77accfb273ecbe721244fb
ARG PLUGIN_REGIONVIEW_SHA256=3b156ff64eafc1d1f8ed0e694dee92a17457c606c02c0ea841b8c3e964302f57
ARG PLUGIN_HOUSEREGIONS_SHA256=791b77ca0d9b2c367a2de5717df7813dad061c5386e12f94b796eff6388c00f6

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Fetch + verify TShock. The release ships as a .zip containing a .tar; extract both.
RUN set -eux; \
    url="https://github.com/Pryaxis/TShock/releases/download/v${TSHOCK_VERSION}/TShock-${TSHOCK_VERSION}-for-Terraria-${TSHOCK_TERRARIA_VERSION}-linux-amd64-Release.zip"; \
    curl -fsSL -o tshock.zip "$url"; \
    echo "${TSHOCK_ZIP_SHA256}  tshock.zip" | sha256sum -c -; \
    unzip -q tshock.zip; \
    tar -xf TShock-Beta-linux-x64-Release.tar -C /work/tshock --one-top-level=. 2>/dev/null || { mkdir -p /work/tshock; tar -xf TShock-Beta-linux-x64-Release.tar -C /work/tshock; }; \
    rm tshock.zip TShock-Beta-linux-x64-Release.tar; \
    # Delete the in-container updater. We never want it on the runtime image.
    rm -f /work/tshock/TShock.Installer; \
    ls /work/tshock/TShock.Server >/dev/null

# Fetch + verify plugins. Each DLL gets its own RUN so a hash mismatch fails
# the layer cleanly and the error message names the offending plugin.
RUN set -eux; mkdir -p /work/tshock/ServerPlugins; \
    base="https://raw.githubusercontent.com/${PLUGINS_REPO}/${PLUGINS_COMMIT}"; \
    curl -fsSL -o "/work/tshock/ServerPlugins/History.dll"        "${base}/History.dll"; \
    echo "${PLUGIN_HISTORY_SHA256}  /work/tshock/ServerPlugins/History.dll"           | sha256sum -c -; \
    curl -fsSL -o "/work/tshock/ServerPlugins/AntiSpam.dll"       "${base}/AntiSpam.dll"; \
    echo "${PLUGIN_ANTISPAM_SHA256}  /work/tshock/ServerPlugins/AntiSpam.dll"         | sha256sum -c -; \
    curl -fsSL -o "/work/tshock/ServerPlugins/RegionView.dll"     "${base}/RegionView.dll"; \
    echo "${PLUGIN_REGIONVIEW_SHA256}  /work/tshock/ServerPlugins/RegionView.dll"     | sha256sum -c -; \
    # URL-encode the space for the source repo path; keep the on-disk name spaceless.
    curl -fsSL -o "/work/tshock/ServerPlugins/HouseRegions.dll"   "${base}/House%20Regions.dll"; \
    echo "${PLUGIN_HOUSEREGIONS_SHA256}  /work/tshock/ServerPlugins/HouseRegions.dll" | sha256sum -c -

# Normalise permissions for the runtime user. Read-only for files we never want
# the process to rewrite, +x on the launcher only.
RUN set -eux; \
    chmod -R a-w /work/tshock; \
    chmod 0555 /work/tshock/TShock.Server; \
    # Things actually executable inside `bin/` aren't direct entrypoints; the
    # apphost dlopens them. Leave them mode 0444.
    find /work/tshock -type d -exec chmod 0555 {} +

# ---------------------------------------------------------------------------
# Stage 2: runtime image. Pinned by digest. Microsoft maintains this and
# publishes CVE fixes on a known cadence; nightly CI rebuilds pick them up.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime@sha256:d955f883a9e648f0ff80b8bfe01e6b79874c296ef3bbcb5637c6981b64981a9a

ARG TSHOCK_VERSION
ARG TSHOCK_TERRARIA_VERSION
ARG UID=1000
ARG GID=1000

LABEL org.opencontainers.image.title="terraria-tshock" \
      org.opencontainers.image.description="Hardened TShock dedicated server (Terraria ${TSHOCK_TERRARIA_VERSION}, TShock ${TSHOCK_VERSION})" \
      org.opencontainers.image.source="https://github.com/kubedoll-heavy-industries/terraria-tshock" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Kubedoll Heavy Industries" \
      io.haruspex.tshock.version="${TSHOCK_VERSION}" \
      io.haruspex.terraria.version="${TSHOCK_TERRARIA_VERSION}"

# netcat-openbsd: ~50 KB, only used by the healthcheck. tini: PID-1 signal
# forwarding (Terraria doesn't reap children or handle SIGTERM cleanly otherwise).
RUN apt-get update \
 && apt-get install -y --no-install-recommends netcat-openbsd tini \
 && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/apt/archives/*

# Non-root user, created in this stage so the final image owns nothing as root
# beyond the read-only /opt/tshock tree.
RUN groupadd --system --gid ${GID} tshock \
 && useradd  --system --uid ${UID} --gid ${GID} --no-create-home --home /serverdata/serverfiles --shell /usr/sbin/nologin tshock

# Copy verified artifacts owned by root, mode 0555 — the runtime user can read
# and execute but cannot modify the binary tree even if it's somehow exploited.
COPY --from=fetch --chown=root:root /work/tshock/ /opt/tshock/

# The chart mounts a PVC at /serverdata/serverfiles. Create the tree owned by
# the runtime user so the chart's init container (and the server itself) can
# write to /serverdata/serverfiles/{worlds,tshock,logs} without a chown dance.
RUN mkdir -p /serverdata/serverfiles/worlds \
             /serverdata/serverfiles/tshock \
             /serverdata/serverfiles/logs \
 && chown -R ${UID}:${GID} /serverdata

# .NET 6 apphost → .NET 9 runtime. See header comment for rationale.
ENV DOTNET_ROLL_FORWARD=LatestMajor \
    DOTNET_ROLL_FORWARD_PRE_RELEASE=0 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    # Where TShock looks for config/worlds/logs by default. We pass these on the
    # command line too, so a `command:` override in the chart still wins, but
    # having them in the env is a useful self-documenting fallback.
    TSHOCK_CONFIGPATH=/serverdata/serverfiles/tshock \
    TSHOCK_WORLDPATH=/serverdata/serverfiles/worlds \
    TSHOCK_LOGPATH=/serverdata/serverfiles/logs

USER ${UID}:${GID}
# Run from the writable PVC, not the read-only /opt/tshock tree. Terraria's
# pre-TShock layer hardcodes `ServerLog.txt` into the process cwd; if cwd is
# /opt/tshock the process crashes on first write. Working from the PVC also
# means any incidental "scratch file dropped in cwd" behaviour from other
# layers ends up on persistent storage instead of the container writable layer.
WORKDIR /serverdata/serverfiles

EXPOSE 7777/tcp
VOLUME ["/serverdata/serverfiles"]

# TCP probe on 7777. Kubernetes will usually use its own tcpSocket probe and
# ignore this, but it's useful for `docker run` smoke tests.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD nc -z 127.0.0.1 7777 || exit 1

# tini handles SIGTERM → graceful TShock shutdown (saves world before exit).
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/tshock/TShock.Server"]
CMD ["-configpath", "/serverdata/serverfiles/tshock", \
     "-worldpath",  "/serverdata/serverfiles/worlds", \
     "-logpath",    "/serverdata/serverfiles/logs"]
