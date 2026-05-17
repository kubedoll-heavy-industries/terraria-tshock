# syntax=docker/dockerfile:1.7
#
# terraria-tshock — hardened, version-pinned TShock container.
#
# Layers (top → bottom = least → most cache-busting):
#   1. fetch      — Debian-slim, downloads + SHA256-verifies TShock and tini.
#   2. runtime    — Ubuntu Resolute (26.04 LTS) chiseled (distroless). Copies
#                   verified artifacts only. No shell, no apt, no package manager.
#
# (Day-1 ships with no baked plugins; see the long comment between stages.)
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
# (Stage 2 — plugin builder — intentionally absent for day-1.)
#
# Plan was to build v6-compatible History/HouseRegion/RegionView from the
# UnrealMultiple/TShockPlugin source. Their build chain depends on a Roslyn
# source generator (`SourceGen`) targeting Microsoft.CodeAnalysis.CSharp 5.3.0
# which only ships with the .NET 10 SDK — but the .NET 10 SDK drops the net6.0
# targeting pack that TShock 6.1 NuGet's transitive graph still references.
# Net effect: no Microsoft-published SDK can both restore TShock 6.1 AND run
# this analyzer cleanly. Fixing it requires either reverse-engineering their
# publish-plugins-zip.ps1 build script or building the full 134-project
# solution. Both are out of scope for the first 6.1 image cut.
#
# Image ships with /opt/tshock/ServerPlugins/TShockAPI.dll only (from upstream
# TShock zip). Operators can mount custom plugins via the chart's plugin
# volume. Re-instating baked plugins is a tracked follow-up.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stage 2 (renumbered): runtime image. Pinned by digest. Distroless — no
# shell, no apt. Microsoft maintains this; nightly CI rebuild absorbs any
# base-layer CVE fix.
# ---------------------------------------------------------------------------
# 10.0-resolute-chiseled-EXTRA (not plain chiseled): TShock's bundled OTAPI
# constructs CultureInfo("en-US") during static init, which throws under
# globalization-invariant mode. The -extra variant ships ICU + tzdata data on
# top of the chiseled base, satisfying that requirement without giving up the
# distroless property (still no shell, no apt, no package manager).
FROM mcr.microsoft.com/dotnet/runtime@sha256:67e60ea4fb14921780de3533841ce9afc64dde30faaf83ae5bb7f5c71abd8871

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

# No baked plugins on day 1 — see Stage 2 deletion comment above.
# /opt/tshock/ServerPlugins/ ships with TShockAPI.dll from the upstream zip.

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
# - DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp: TShock 6.1.0 ships as a single-file
#   apphost (PublishSingleFile=true) which unpacks its embedded native libs
#   (notably sqlite) to disk at startup. Default extract dir is /, which is
#   read-only on the chiseled base. /tmp is world-writable in chiseled and
#   safe for ephemeral extract — the apphost will re-extract on every boot
#   into /tmp/.net/TShock.Server/<hash>/.
# - DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false: the -extra base ships ICU
#   data; OTAPI requires a real (non-invariant) culture during static init
#   (constructs CultureInfo("en-US") which throws under invariant mode).
#   This env var overrides the inherited =true from the chiseled base.
# - DOTNET_RUNNING_IN_CONTAINER inherited =true.
ENV DOTNET_ROLL_FORWARD=LatestMajor \
    DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
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
