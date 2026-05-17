# syntax=docker/dockerfile:1.7
#
# terraria-tshock — hardened, version-pinned TShock container.
#
# Layers (top → bottom = least → most cache-busting):
#   1. fetch      — Debian-slim, downloads + SHA256-verifies TShock and tini.
#   2. plugins    — .NET 10 SDK, clones UnrealMultiple/TShockPlugin at a pinned
#                   commit and builds 3 plugins against TShock 6.1.0 NuGet.
#   3. runtime    — Ubuntu Resolute (26.04 LTS) chiseled (distroless). Copies
#                   verified artifacts only. No shell, no apt, no package manager.
#
# Why chiseled?
#   No shell = no shell-escape class of CVE. No package manager = nothing to
#   update at runtime, nothing for Trivy to flag at the OS layer. The price is
#   that pod debugging needs `kubectl debug --image=mcr.microsoft.com/dotnet/runtime:10.0-resolute
#   --target=terraria` to attach an ephemeral container with userspace tools.
#   See OPS.md.
#
# Why glibc-based and not Alpine?
#   TShock.Server is a glibc-linked ELF (NEEDED libc.so.6, libstdc++.so.6, ...).
#   Alpine ships musl; running glibc binaries on Alpine needs the `gcompat`
#   shim, which is not 100% glibc-compatible and adds an attack surface. Resolute
#   chiseled gives us native glibc (Ubuntu 26.04 LTS) plus distroless ergonomics.
#
# Why .NET 10 runtime, not .NET 9?
#   TShock 6.1.0 ships as a net9.0 apphost. .NET 9 is STS (EOL May 2026); .NET
#   10 is the current LTS. DOTNET_ROLL_FORWARD=LatestMajor coerces the net9
#   apphost onto the .NET 10 shared framework — exact pattern we've validated
#   previously (net6 TShock 5.2.4 rolled forward to .NET 10 ran clean).

# ---------------------------------------------------------------------------
# Stage 1: fetch + verify the TShock release and tini. Pinned by digest so
# a hostile mirror cannot serve us a different debian.
# ---------------------------------------------------------------------------
FROM debian@sha256:67b30a61dc87758f0caf819646104f29ecbda97d920aaf5edc834128ac8493d3 AS fetch

ARG TARGETARCH
RUN [ "$TARGETARCH" = "amd64" ] || { echo "this image is amd64-only; got $TARGETARCH"; exit 1; }

# TShock release.
ARG TSHOCK_VERSION=6.1.0
ARG TSHOCK_TERRARIA_VERSION=1.4.5.6
ARG TSHOCK_ZIP_SHA256=c4a63624e49422e46967c4cb6a72b698acb96dcc645e5b1daaa0f00e2cb98db9

# tini (PID 1 + signal forwarding). Static glibc build, no runtime deps.
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256=c5b0666b4cb676901f90dfcb37106783c5fe2077b04590973b885950611b30ee

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Fetch + verify TShock. Release ships as .zip wrapping a .tar; unwrap both.
RUN set -eux; \
    url="https://github.com/Pryaxis/TShock/releases/download/v${TSHOCK_VERSION}/TShock-${TSHOCK_VERSION}-for-Terraria-${TSHOCK_TERRARIA_VERSION}-linux-x64-Release.zip"; \
    curl -fsSL -o tshock.zip "$url"; \
    echo "${TSHOCK_ZIP_SHA256}  tshock.zip" | sha256sum -c -; \
    unzip -q tshock.zip; \
    mkdir -p /work/tshock; \
    tar -xf TShock-Beta-linux-x64-Release.tar -C /work/tshock; \
    rm tshock.zip TShock-Beta-linux-x64-Release.tar; \
    # Delete the in-container updater. We never want it on the runtime image.
    rm -f /work/tshock/TShock.Installer; \
    [ -f /work/tshock/TShock.Server ]

# Fetch + verify tini static binary.
RUN set -eux; \
    curl -fsSL -o /work/tini "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-amd64"; \
    echo "${TINI_SHA256}  /work/tini" | sha256sum -c -; \
    chmod 0555 /work/tini

# Normalise permissions for the runtime user. Read-only for files we never want
# the process to rewrite, +x on the launcher only.
RUN set -eux; \
    chmod -R a-w /work/tshock; \
    chmod 0555 /work/tshock/TShock.Server; \
    find /work/tshock -type d -exec chmod 0555 {} +

# ---------------------------------------------------------------------------
# Stage 2: plugin builder. Clones UnrealMultiple/TShockPlugin at a pinned
# commit (GPL-3.0) and builds 3 plugins against the TShock 6.1.0 NuGet
# package the repo's template.targets references. The resulting DLLs land in
# ./out/Release/ per their build convention.
# ---------------------------------------------------------------------------
# .NET 9 SDK (not 10) — TShock 6.1's transitive dep graph still references
# net6.0 (e.g. via TerrariaServerAPI), and the .NET 10 SDK drops the net6
# targeting pack. The .NET 9 SDK still ships net6/net7/net8/net9 packs and
# can produce net9.0 plugin DLLs that load on the .NET 10 runtime via the
# DOTNET_ROLL_FORWARD env var in the runtime stage.
FROM mcr.microsoft.com/dotnet/sdk@sha256:087fc98e5c6ffcea6c3e276c135c4a6717c589d9509a09cc22e7c634830a4db8 AS plugins

ARG PLUGINS_REPO=UnrealMultiple/TShockPlugin
# Pinned commit: 2026-05-11. Refresh when bumping plugin set.
ARG PLUGINS_COMMIT=221ff312bc357512af35fdafd5afdf130cf46951

# Clone the exact commit (depth-1 ref-by-tag-on-the-fly: fetch the commit, no history).
WORKDIR /src
RUN git init -q . \
 && git remote add origin "https://github.com/${PLUGINS_REPO}.git" \
 && git fetch --depth 1 -q origin "${PLUGINS_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && git submodule update --init --recursive --depth 1 -q

# Build each plugin. template.targets pins net9.0 + TShock 6.1.0 NuGet.
# Output lands at /src/out/Release/<PluginName>.dll per their build convention.
#
# Build order matters: HouseRegion has a ProjectReference to LazyAPI, which
# has a ProjectReference to SourceGen as an Analyzer (OutputItemType=Analyzer,
# ReferenceOutputAssembly=false). SourceGen is a Roslyn source generator that
# emits IProgressMap/ProgressHelper. Building HouseRegion in one shot fails
# because the analyzer DLL isn't on disk yet when LazyAPI compiles. So build
# SourceGen first (forces the analyzer DLL), then build the plugins one-by-one.
#
# Skipping --no-restore: `dotnet build` does its own restore that correctly
# walks ProjectReferences (separate `dotnet restore <one csproj>` does not).
RUN dotnet build src/SourceGen/SourceGen.csproj   -c Release --verbosity minimal
RUN dotnet build src/History/History.csproj       -c Release --verbosity minimal
RUN dotnet build src/HouseRegion/HouseRegion.csproj -c Release --verbosity minimal
RUN dotnet build src/RegionView/RegionView.csproj -c Release --verbosity minimal

# Stage the plugin DLLs in a clean tree we'll COPY into the runtime image.
# Only the *plugin* DLLs — not TShockAPI/Terraria deps, which are already in
# the TShock release zip. UnrealMultiple's build drops embedded i18n into the
# DLL itself, so we don't need to ship the .mo files separately.
RUN set -eux; \
    mkdir -p /staged; \
    cp /src/out/Release/History.dll      /staged/History.dll; \
    cp /src/out/Release/HouseRegion.dll  /staged/HouseRegion.dll; \
    cp /src/out/Release/RegionView.dll   /staged/RegionView.dll; \
    chmod 0444 /staged/*.dll

# ---------------------------------------------------------------------------
# Stage 3: runtime image. Pinned by digest. Distroless — no shell, no apt.
# Microsoft maintains this; nightly CI rebuild absorbs any base-layer CVE fix.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime@sha256:e47cc1e32cd37647d0505f9a3192a5cf1894e1fc70df0e7bcb133ce2fec5ea7f

ARG TSHOCK_VERSION
ARG TSHOCK_TERRARIA_VERSION

LABEL org.opencontainers.image.title="terraria-tshock" \
      org.opencontainers.image.description="Hardened TShock 6.1.0 server image for Terraria ${TSHOCK_TERRARIA_VERSION}, .NET 10 LTS on Ubuntu 26.04 chiseled" \
      org.opencontainers.image.source="https://github.com/kubedoll-heavy-industries/terraria-tshock" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Kubedoll Heavy Industries" \
      io.haruspex.tshock.version="${TSHOCK_VERSION}" \
      io.haruspex.terraria.version="${TSHOCK_TERRARIA_VERSION}"

# Copy verified artifacts. Owner = root because the runtime image has no shell
# to invoke `chown`; the runtime user (1000) reads but can't modify.
COPY --from=fetch --chown=root:root --chmod=0555 /work/tini /usr/local/bin/tini
COPY --from=fetch --chown=root:root /work/tshock/ /opt/tshock/

# Bake the v6-compatible plugins next to TShock's own ServerPlugins tree.
# The TShock release zip ships ServerPlugins/TShockAPI.dll already; we just add
# our 3 plugin DLLs alongside it.
COPY --from=plugins --chown=root:root /staged/ /opt/tshock/ServerPlugins/

# Writable PVC tree. Chiseled has no shell, so we can't RUN mkdir + chown. The
# WORKDIR directive below creates /serverdata/serverfiles automatically (Docker
# creates parents); ownership defaults to root:root, but the chart mounts a PVC
# at this path with fsGroup=1000, which Kubernetes uses to chown the volume
# contents on mount. So the inherited root:root ownership of the in-image dir
# is replaced at runtime by the PVC's fsGroup-owned tree. The chart's existing
# init container creates worlds/, tshock/, logs/ subdirs on first start.

# Runtime env.
# - DOTNET_ROLL_FORWARD=LatestMajor: lets TShock's net9 apphost load on the
#   .NET 10 shared framework. Validated previously (net6→net10 roll-forward).
# - DOTNET_SYSTEM_GLOBALIZATION_INVARIANT inherited =true from the chiseled
#   base. We leave it true — chiseled doesn't ship ICU data and TShock's i18n
#   uses .mo files that don't require .NET's globalization stack.
# - DOTNET_RUNNING_IN_CONTAINER inherited =true.
ENV DOTNET_ROLL_FORWARD=LatestMajor \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

USER 1000:1000
WORKDIR /serverdata/serverfiles

EXPOSE 7777/tcp
VOLUME ["/serverdata/serverfiles"]

# No HEALTHCHECK. K8s readinessProbe (tcpSocket: 7777) is the right place for
# liveness in cluster, and chiseled has no shell/nc to back a Docker
# HEALTHCHECK anyway. Pryaxis's own image makes the same choice.

# tini as PID 1 for clean SIGTERM → TShock graceful shutdown (saves world
# before exit). The chiseled base's default ENTRYPOINT is `dotnet`; we
# override entirely because TShock ships as a single-file apphost ELF, not
# a managed dll.
ENTRYPOINT ["/usr/local/bin/tini", "--", "/opt/tshock/TShock.Server"]
CMD ["-configpath", "/serverdata/serverfiles/tshock", \
     "-worldpath",  "/serverdata/serverfiles/worlds", \
     "-logpath",    "/serverdata/serverfiles/logs"]
