# syntax=docker/dockerfile:1.7
#
# terraria-tshock — hardened, version-pinned TShock container.
#
# Layers (top → bottom = least → most cache-busting):
#   1. fetch      — Debian-slim, downloads + SHA256-verifies TShock and tini.
#   2. plugins    — .NET 9 SDK, builds History/HouseRegion/RegionView from
#                   UnrealMultiple/TShockPlugin source (pinned commit).
#   3. runtime    — Ubuntu Resolute (26.04 LTS) + .NET 10 LTS runtime. Full
#                   apt-based base (NOT chiseled).
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
# Stage 2: plugin builder. Clones UnrealMultiple/TShockPlugin at a pinned
# commit and builds the three v6-compatible plugins we want baked into the
# image: History, HouseRegion, RegionView. Uses .NET 9 SDK exclusively —
# matches upstream CI (.github/workflows/build.yml: dotnet-version 9.x).
#
# Earlier notes claimed an SDK-version coupling required .NET 10 SDK for the
# Roslyn source generator (Microsoft.CodeAnalysis.CSharp 5.3.0). That was a
# misread: upstream CI ships green on .NET 9 SDK alone, and source inspection
# confirms our three target plugins do not consume any SourceGen-emitted
# types (ProgressHelper/IProgressMap are only referenced by LazyAPI and
# CaiBotLite, not by History/HouseRegion/RegionView's own code). HouseRegion
# does transitively pull in LazyAPI as a project ref, which forces the
# SourceGen build; upstream proves that build works under net9.0 SDK.
#
# AntiSpam: no v6-compatible equivalent in UnrealMultiple's collection (or
# anywhere we could find). Skipped — recorded in plugins.lock.
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS plugins

# Pin the UnrealMultiple/TShockPlugin commit; bump deliberately, never float.
ARG TSHOCK_PLUGINS_COMMIT=221ff312bc357512af35fdafd5afdf130cf46951
ARG TSHOCK_PLUGINS_REPO=https://github.com/UnrealMultiple/TShockPlugin.git

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN set -eux; \
    git init; \
    git remote add origin "${TSHOCK_PLUGINS_REPO}"; \
    git fetch --depth 1 origin "${TSHOCK_PLUGINS_COMMIT}"; \
    git checkout FETCH_HEAD; \
    git rev-parse HEAD > /src/.plugins-commit

# Build the three target plugins. Each `dotnet build` restores + compiles its
# csproj (and any project refs — HouseRegion pulls LazyAPI + SourceGen). We
# intentionally do NOT build Plugin.slnx (the 134-project solution) — that
# would drag in submodules and unrelated plugins we don't ship.
#
# `--use-current-runtime` is omitted; default RID is fine. UseAppHost=false
# would be wrong here — we want managed assemblies for ServerPlugins, not
# apphosts. The default for non-Exe csprojs is what we want.
RUN set -eux; \
    for proj in src/History/History.csproj \
                src/HouseRegion/HouseRegion.csproj \
                src/RegionView/RegionView.csproj; do \
        echo ">>> building $proj"; \
        dotnet build "$proj" -c Release -v minimal; \
    done

# Collect the produced DLLs. template.targets pins OutputPath to
# ../../out/$(Configuration) which lands at /src/out/Release/.
RUN set -eux; \
    mkdir -p /plugins; \
    cp /src/out/Release/History.dll      /plugins/History.dll; \
    cp /src/out/Release/HouseRegion.dll  /plugins/HouseRegion.dll; \
    cp /src/out/Release/RegionView.dll   /plugins/RegionView.dll; \
    # LazyAPI is HouseRegion's dependency — ship it alongside.
    cp /src/out/Release/LazyAPI.dll      /plugins/LazyAPI.dll; \
    # linq2db is LazyAPI's runtime dep; CopyLocalLockFileAssemblies=true
    # (from template.targets) means it lands in the same out dir.
    cp /src/out/Release/linq2db.dll      /plugins/linq2db.dll; \
    chmod 0444 /plugins/*.dll; \
    # Record SHA256 of every shipped DLL for plugins.lock cross-check.
    sha256sum /plugins/*.dll > /plugins/SHA256SUMS; \
    cat /plugins/SHA256SUMS

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
 # /usr/bin/pebble is Canonical's init/supervisor — we use tini as PID 1, so
 # pebble is unused weight. Trivy flags it for Go stdlib CVEs (CVE-2026-33811,
 # -33814, -39820, -39836, -42499) that the base image ships with. Remove it
 # to eliminate the findings cleanly until MS refreshes the base digest.
 && rm -f /usr/bin/pebble \
 && rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/apt/archives/*

# Copy verified artifacts. Owner = root, mode = read-only: the runtime user
# (uid 1000) can read and execute but cannot modify the binary tree even if
# something inside it is somehow exploited.
COPY --from=fetch --chown=root:root --chmod=0555 /work/tini /usr/local/bin/tini
COPY --from=fetch --chown=root:root /work/tshock/ /opt/tshock/

# Baked plugins. /opt/tshock/ServerPlugins/ already contains TShockAPI.dll
# from the upstream zip; we drop our additions next to it. Owner=root,
# mode=read-only — uid 1000 can load them but cannot rewrite.
COPY --from=plugins --chown=root:root --chmod=0444 /plugins/*.dll /opt/tshock/ServerPlugins/

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
