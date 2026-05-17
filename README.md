# terraria-tshock

Hardened, version-pinned, plugin-baked Terraria/TShock container image for the
[Haruspex](https://github.com/cagyirey/haruspex) Kubernetes cluster.

Published to `ghcr.io/kubedoll-heavy-industries/terraria-tshock`.

## Why a custom image?

The upstream `ich777/terrariaserver:tshock` image we previously used had several
properties that didn't fit our threat model:

- Runs as `root`, then `chown`s mounted volumes, then drops to a user.
- Downloads the TShock binary from GitHub releases at container start. The
  version is whatever GitHub serves at runtime, with no signature or hash
  verification.
- Ships `gotty` (an unmaintained web-terminal proxy, last released 2017) on the
  service port by default.
- No SBOM, no signature, no provenance attestation.

This image replaces all of that with build-time pinning and supply-chain controls.

## Properties

- **Distroless from PID 1.** Built on Microsoft's chiseled .NET 10 LTS runtime
  (`mcr.microsoft.com/dotnet/runtime:10.0-resolute-chiseled`, Ubuntu 26.04 LTS).
  No shell, no package manager, no setuid binaries. Container runs as
  `uid 1000 / gid 1000`. See [`OPS.md`](./OPS.md) for the pod-debug pattern
  (`kubectl debug` with an ephemeral container).
- **TShock 6.1.0 for Terraria 1.4.5.6**, native .NET 9 apphost, rolled forward
  onto the .NET 10 LTS runtime via `DOTNET_ROLL_FORWARD=LatestMajor`.
- **All inputs SHA256-pinned at build time** — TShock release zip and tini
  static binary. See [`plugins.lock`](./plugins.lock). Mismatch on any pin
  fails the build closed.
- **No runtime updates.** No `curl github.com` from the running container, no
  `TShock.Installer` (stripped at build time), no gotty.
- **No baked plugins on day 1.** `ServerPlugins/` contains only TShockAPI.dll
  from the upstream zip. The chart's plugin volume can overlay custom plugins
  at runtime. Re-baking is tracked as a follow-up — see [`plugins.lock`](./plugins.lock)
  for the sourcing analysis.
- **No Docker `HEALTHCHECK`.** Chiseled image has no `nc`/shell. Use K8s
  `readinessProbe.tcpSocket: { port: 7777 }` in the chart (already configured).
- **amd64 only.** Our cluster nodes are amd64; arm64 can be added by extending
  the build matrix in `.github/workflows/build.yml`.

## Image tags

- `:<tshock-version>` — e.g. `:5.2.1`. Mutable across rebuilds of the same
  TShock version (gets security updates from base-layer refreshes).
- `:<tshock-version>-<build>` — e.g. `:5.2.1-3`. Immutable; pins to one build.
- `:latest` — only published from `main` branch builds.

Production deployments should pin by **digest** (`@sha256:...`), which is
recorded with every successful CI run.

## Volume layout (chart-compatible)

The image is a drop-in replacement for the TrueForge `terraria-tshock` Helm
chart, which mounts the writable server tree at `/serverdata/serverfiles`:

```
/serverdata/serverfiles/
  worlds/      # writable world data (PVC)
  tshock/      # TShock config + SQLite (PVC; config.json deep-merged via the chart's init container)
  logs/        # TShock logs (PVC)
```

The TShock + plugin DLLs that ship with the image live under `/opt/tshock/` and
are read-only; mutable runtime state stays under `/serverdata/serverfiles`.

## Supply-chain

Every published image carries:

- A **cosign keyless signature** (OIDC issuer = GitHub Actions).
- A **SLSA build provenance attestation** discoverable via
  `gh attestation verify`.
- A **Trivy scan** that gates the build on HIGH/CRITICAL CVEs.

Verify a signature:

```sh
cosign verify \
  --certificate-identity-regexp 'https://github.com/kubedoll-heavy-industries/terraria-tshock/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kubedoll-heavy-industries/terraria-tshock:<tag>
```

Verify provenance:

```sh
gh attestation verify oci://ghcr.io/kubedoll-heavy-industries/terraria-tshock:<tag> \
  --owner kubedoll-heavy-industries
```

## License

MIT — see [LICENSE](./LICENSE).

TShock itself is GPL-3.0 (Pryaxis/TShock). This repo packages it; the binary
license still applies to consumers of the binary inside the image.
