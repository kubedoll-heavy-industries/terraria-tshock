# Changes

## Plugins re-baked (task #9)

Baked four DLLs into `/opt/tshock/ServerPlugins/`:
History, HouseRegion, RegionView, LazyAPI (+ linq2db as a transitive runtime dep).
Sourced from `UnrealMultiple/TShockPlugin` at commit
`221ff312bc357512af35fdafd5afdf130cf46951`.

### Approach that worked

Added a `plugins` stage to the Dockerfile using `mcr.microsoft.com/dotnet/sdk:9.0`
and ran `dotnet build` per `.csproj` for each target plugin (not the whole
134-project `Plugin.slnx`). This matches the upstream CI's
`setup-dotnet@v5` with `dotnet-version: 9.x`.

### Why the prior attempt's blocker was a misread

The earlier note claimed the Roslyn source generator (`SourceGen`,
`Microsoft.CodeAnalysis.CSharp 5.3.0`) required the .NET 10 SDK, which
in turn dropped the net6.0 targeting pack that TShock 6.1's transitive
graph references — an unresolvable bind.

In practice:

- Upstream CI ships green on .NET 9 SDK alone (see their
  `.github/workflows/build.yml`).
- Of the three target plugins, only `HouseRegion` transitively pulls
  `LazyAPI`, which is the actual consumer of the SourceGen-emitted
  `ProgressHelper`/`IProgressMap` types. `History` and `RegionView`
  don't touch the generated code at all.
- `Microsoft.CodeAnalysis.CSharp 5.3.0` is a NuGet package the analyzer
  is *built against*, not a SDK-bundled host requirement. The .NET 9
  SDK loads it fine.

So the right move was to stop trying to reconcile SDK versions and just
match the upstream invocation.

### AntiSpam — skipped

No v6-compatible AntiSpam exists in `UnrealMultiple/TShockPlugin`'s
collection of 134 plugins, and no other public source surfaces a port.
The 5.x AntiSpam from `RenderBr/tShock-v5-plugins` is ABI-locked to
TShock 5.x. Operators who need chat anti-spam can mount a custom
plugin via the chart's plugin volume.

### Verification

Added `Smoke test (plugin load)` step to `.github/workflows/build.yml`
that boots the image and greps for `Plugin <name> .* initiated` in the
TShock startup log for each of `History`, `HouseRegion`, `RegionView`.
Job fails if any plugin doesn't initiate. Same shape as the existing
`Smoke test (baseline)` step.
