# Operations notes

> **Apple Silicon dev note.** Do NOT trust `docker run` smoke-test results
> for this image on M-series Macs. Docker Desktop runs amd64 images under
> qemu user-mode emulation, and qemu has known issues with modern .NET's
> `Span<T>` / unsafe-code paths that surface as cryptic crashes during
> OTAPI/Terraria's static init (`LanguageManager.ProcessCopyCommandsInTexts
> NullReferenceException`, `qemu: uncaught target signal 6/11`, etc.).
> These do **not** reproduce on real amd64 hardware. Use the CI smoke-test
> job (`.github/workflows/build.yml`) for boot verification.

## Pod debugging

The runtime image is `mcr.microsoft.com/dotnet/runtime:10.0-resolute`
(Ubuntu 26.04 LTS, full apt-based userspace). `kubectl exec` works:

```sh
kubectl exec -it -n games <terraria-pod-name> -- bash
```

We tried the chiseled and chiseled-extra variants for a distroless property,
but OTAPI/Terraria's globalization stack has userspace assumptions that we
couldn't satisfy without forking OTAPI. Hardening is restored at the K8s
podSpec level — see "Pod-level hardening" below.

## Pod-level hardening (chart-side)

The chart should set these on the main container:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
volumes:
  - name: tmp
    emptyDir:
      medium: Memory
      sizeLimit: 256Mi
volumeMounts:
  - name: tmp
    mountPath: /tmp
```

`/tmp` is required as a tmpfs emptyDir because `DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp`
needs writable scratch for the TShock single-file apphost to unpack.

A NetworkPolicy should restrict egress to:
- UDP/53 (DNS) to cluster CoreDNS
- TCP/443 to `steamcommunity.com` only if `terraria.secure: true` is set
  (Steam-side auth handshake). Otherwise no egress needed.

## Healthcheck

Image declares a Docker `HEALTHCHECK` (`nc -z 127.0.0.1 7777`) for
`docker run` smoke tests. K8s `readinessProbe.tcpSocket: { port: 7777 }`
remains the authoritative liveness check in cluster.

## Build-time pin set

Every external artifact is SHA256-pinned in [`plugins.lock`](./plugins.lock).
CI verifies all hashes before the runtime image is assembled. Mismatch on any
pin = build fails closed.

When bumping TShock or the plugin source commit, update **both** the matching
`ARG` default in `Dockerfile` AND the entry in `plugins.lock`. CI doesn't
parse plugins.lock for build inputs — it's the human-readable mirror.
