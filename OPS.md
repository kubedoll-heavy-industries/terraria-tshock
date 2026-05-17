# Operations notes

## Pod debugging — distroless image, no in-pod shell

The runtime image is `mcr.microsoft.com/dotnet/runtime:10.0-resolute-chiseled`
(Ubuntu 26.04 LTS, distroless). It has no `sh`, no `bash`, no `apt`, no `ps`,
no `ls`. This is intentional — no shell means no shell-escape class of
vulnerability — but it means `kubectl exec -it ... -- sh` will not work.

To poke at a running TShock pod, attach an ephemeral container with a full
Ubuntu Resolute userspace and the same PID namespace as the TShock container:

```sh
kubectl debug -it -n games <terraria-pod-name> \
  --image=mcr.microsoft.com/dotnet/runtime:10.0-resolute \
  --target=terraria \
  -- bash
```

The `--target=terraria` flag shares PIDs with the named container so `ps`,
`/proc/<pid>/`, `lsof`, etc. work against the running TShock process. Logs go
via `kubectl logs` as usual (stdout/stderr is unchanged).

For `nsenter`-style network debugging, swap `dotnet/runtime:10.0-resolute` for
`nicolaka/netshoot` and the debug container will land in the pod's network
namespace with tcpdump/curl/dig/etc.

## Healthcheck

The image declares no Docker `HEALTHCHECK`. K8s `readinessProbe.tcpSocket`
(port 7777) is the right place for liveness/readiness in cluster. The chart we
deploy with already sets this; `docker run` smoke tests just rely on the
process exit code.

## Build-time pin set

Every external artifact is SHA256-pinned in [`plugins.lock`](./plugins.lock).
CI verifies all hashes before the runtime image is assembled. Mismatch on any
pin = build fails closed.

When bumping TShock or the plugin source commit, update **both** the matching
`ARG` default in `Dockerfile` AND the entry in `plugins.lock`. CI doesn't
parse plugins.lock for build inputs — it's the human-readable mirror.
