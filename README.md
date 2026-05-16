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

- **Non-root from PID 1.** Built on a minimal Debian-slim base; the container
  runs as `uid 1000 / gid 1000` with no setuid binaries.
- **Pinned .NET 9 ASP.NET Core runtime** copied from an official Microsoft image
  digest at build time.
- **Pinned TShock release** fetched at build time, SHA256-verified against a
  build-arg checksum. The version baked into the image is exactly the version
  we built — no runtime drift.
- **Plugins baked in** at known versions: see [`plugins.lock`](./plugins.lock).
- **No runtime updates.** No `curl github.com` in the entrypoint, no gotty.
- **TCP healthcheck** on port `7777` (the Terraria game port).
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
