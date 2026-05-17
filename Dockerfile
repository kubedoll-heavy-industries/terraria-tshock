# syntax=docker/dockerfile:1.7
#
# terraria-tshock — hardened, version-pinned TShock container.
#
# Layers (top → bottom = least → most cache-busting):
#   1. fetch      — Debian-slim, downloads + SHA256-verifies TShock and tini.
#   2. runtime    — Ubuntu Resolute (26.04 LTS) + .NET 10 LTS runtime. Full
#                   apt-based base (NOT chiseled).
#
# (Day-1 ships with no baked plugins; see the long comment between stages.)
#
# Why non-chiseled?
#   Tried chiseled-extra first; it boots .NET fine but OTAPI's globalization
#   stack has deeper assumptions about a real userspace than we can satisfy
#   without forking OTAPI. Hardening posture is restored at the K8s podSpec
#   level (runAsNonRoot, readOnlyRootFilesystem with /tmp tmpfs, drop ALL
#   capabilities, seccomp RuntimeDefault, NetworkPolicy egress restriction).
#   See OPS.md.
#
# Why glibc-based and not Alpine?
#   TShock.Server is a glibc-linked ELF (NEEDED libc.so.6, libstdc++.so.6, ...).
#   Alpine ships musl; running glibc binaries on Alpine needs the `gcompat`
#   shim, which is not 100% glibc-compatible and adds an attack surface.
#   Resolute (Ubuntu 26.04 LTS) gives us native glibc.
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
# Stage 2: runtime image. Ubuntu 26.04 LTS + .NET 10 LTS runtime, pinned by
# digest. Microsoft maintains this; nightly CI rebuild absorbs any base-layer
# CVE fix.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime@sha256:20b918a3f49c838e57179475a16df93353c2f282be801e0135b699846bccc605

ARG TSHOCK_VERSION
ARG TSHOCK_TERRARIA_VERSION

LABEL org.opencontainers.image.title="terraria-tshock" \
      org.opencontainers.image.description="Hardened TShock 6.1.0 server image for Terraria ${TSHOCK_TERRARIA_VERSION}, .NET 10 LTS on Ubuntu 26.04" \
      org.opencontainers.image.source="https://github.com/kubedoll-heavy-industries/terraria-tshock" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Kubedoll Heavy Industries" \
      io.haruspex.tshock.version="${TSHOCK_VERSION}" \
      io.haruspex.terraria.version="${TSHOCK_TERRARIA_VERSION}"

# netcat-openbsd: ~50 KB, only used by a future docker-side HEALTHCHECK or
# operator smoke tests. tini handles PID 1 + SIGTERM forwarding.
# Set up uid 1000 as 'tshock' (Resolute's adduser ships as a Perl shim that
# wants gettext; --no-create-home + --gecos="" + --disabled-password keeps it
# light). Trim apt artefacts at the end so Trivy doesn't flag stale pkg meta.
# Resolute ships an 'ubuntu' user at uid 1000 / gid 1000 with sudo + several
# secondary groups (adm, dialout, cdrom, sudo, audio, video, plugdev). Remove
# it cleanly first so the 1000:1000 slot is free, then create our minimal
# 'tshock' user with no secondary groups and a nologin shell.
RUN apt-get update \
 && apt-get install -y --no-install-recommends netcat-openbsd \
 && userdel --remove ubuntu 2>/dev/null || true \
 && groupadd --system --gid 1000 tshock \
 && useradd  --system --uid 1000 --gid 1000 --no-create-home \
             --home /serverdata/serverfiles --shell /usr/sbin/nologin tshock \
 && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/apt/archives/*

# Copy verified artifacts. Owner = root, mode = read-only: the runtime user
# (uid 1000) can read and execute but cannot modify the binary tree even if
# something inside it is somehow exploited.
COPY --from=fetch --chown=root:root --chmod=0555 /work/tini /usr/local/bin/tini
COPY --from=fetch --chown=root:root /work/tshock/ /opt/tshock/

# Make /opt/tshock itself writable by the runtime user so Terraria's pre-TShock
# layer can create its hardcoded ServerLog.txt in cwd. We chmod only the
# directory, not its contents (which stay 0555/0444 from the fetch stage's
# `chmod -R a-w`). This is the narrowest possible workaround for OTAPI's
# vanilla-Terraria ServerLog.txt-in-cwd assumption.
RUN chmod 0755 /opt/tshock && chown 1000:1000 /opt/tshock

# No baked plugins on day 1 — see Stage 2 deletion comment above.
# /opt/tshock/ServerPlugins/ ships with TShockAPI.dll from the upstream zip.

# Pre-create the writable PVC tree owned by uid 1000. The chart mounts a PVC
# at /serverdata/serverfiles with fsGroup=1000; subdirs are created by the
# chart's init container OR (if we wire it via ConfigMap-render) by TShock
# itself on first boot once it can write into the PVC.
RUN mkdir -p /serverdata/serverfiles/worlds \
             /serverdata/serverfiles/tshock \
             /serverdata/serverfiles/logs \
 && chown -R 1000:1000 /serverdata

# Runtime env.
# - DOTNET_ROLL_FORWARD=LatestMajor: lets TShock's net9 apphost load on the
#   .NET 10 shared framework. Validated previously (net6→net10 roll-forward).
# - DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp: TShock 6.1.0 ships as a single-file
#   apphost (PublishSingleFile=true) which unpacks its embedded native libs
#   (notably sqlite) to disk at startup. Default extract dir is /, which we
#   set read-only at the K8s podSpec level (readOnlyRootFilesystem: true).
#   /tmp is mounted as a tmpfs emptyDir by the chart for this purpose; the
#   apphost re-extracts on every boot into /tmp/.net/TShock.Server/<hash>/.
# - DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false: OTAPI requires a real
#   (non-invariant) culture during static init (constructs CultureInfo("en-US")
#   which throws under invariant mode). Resolute non-chiseled ships full ICU
#   so this works out of the box, but the env var documents the intent.
# - DOTNET_RUNNING_IN_CONTAINER=true: explicit because we override the default.
ENV DOTNET_ROLL_FORWARD=LatestMajor \
    DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

USER 1000:1000
# Run from the writable PVC, not the read-only /opt/tshock tree. Terraria's
# pre-TShock layer hardcodes ServerLog.txt into the process cwd; if cwd is
# /opt/tshock the process crashes on first write. Working from the PVC also
# means any incidental "scratch file in cwd" behavior lands on persistent
# storage instead of /tmp.
WORKDIR /serverdata/serverfiles

EXPOSE 7777/tcp
VOLUME ["/serverdata/serverfiles"]

# TCP probe on 7777. K8s readinessProbe (tcpSocket: 7777) is still the
# authoritative liveness check in cluster; this HEALTHCHECK is for `docker run`
# smoke tests and operator one-offs.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD nc -z 127.0.0.1 7777 || exit 1

# tini as PID 1 for clean SIGTERM → TShock graceful shutdown (saves world
# before exit). We override the base's default ENTRYPOINT entirely because
# TShock ships as a single-file apphost ELF, not a managed dll.
ENTRYPOINT ["/usr/local/bin/tini", "--", "/opt/tshock/TShock.Server"]
CMD ["-configpath", "/serverdata/serverfiles/tshock", \
     "-worldpath",  "/serverdata/serverfiles/worlds", \
     "-logpath",    "/serverdata/serverfiles/logs"]
