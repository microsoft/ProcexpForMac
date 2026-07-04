# Process Explorer for macOS

A native, idiomatic macOS port of Sysinternals **Process Explorer**, reproducing the look,
feel, and equivalent functionality of the Windows version (source in `../ProcExp`).

## Status

**Feature-complete for v1.** A native macOS Process Explorer with a live process
tree, per-process detail, system-wide graphs, a menu-bar CPU icon, an optional
privileged helper, and a scripted signing/notarization release pipeline.
Builds and runs on macOS 14+ with Xcode 26.

**Implemented features:**
- **Live process tree** (`NSOutlineView`) with color-coded rows, per-process CPU
  sparklines, natural/column sorting, live filtering, and difference highlighting
  for new processes.
- **Lower pane** — per-process loaded modules and open handles (file descriptors),
  with sorting and filtering.
- **Process Properties** window (Image / Performance / Threads / TCP-IP /
  Environment / Strings / Security tabs), live-updating.
- **System Information** window — multi-graph CPU (total + per-core), memory,
  I/O, network, and GPU history.
- **Menu-bar CPU-history icon** with a quick-glance popup and window activation.
- **Process actions** — kill, kill-tree, suspend/resume, set priority (nice),
  restart, bring-to-front, with confirmation prompts.
- **Preferences** — refresh interval, columns, row colors, confirm-before-kill,
  signature verification, difference-highlight duration (persisted).
- **Code-signing status** + Keychain-backed VirusTotal lookups.
- **Optional privileged root helper** (`SMAppService` + XPC) for cross-user
  thread sampling and privileged actions.
- **About panel**, **app icon**, and a **Release DMG + notarization pipeline**
  (see below).

### Engine libraries (compile clean, validated at runtime via `ProcexpSmoke`)
- **W0 `ProcexpModel`** — shared contracts (`ProcessRecord`, `ProcessSnapshot`, provider
  protocols, `Column`, coloring) + `MockDataProvider` (animated 150-process fake tree).
- **W1 `ProcexpSampling`** — `LibprocDataProvider`: real process sampling via libproc/sysctl
  (samples ~1000 live processes incl. SIP-protected ones, accurate CPU% deltas, tree, fds).
- **W4 `ProcexpGraphs`** — `SystemStatsProvider` (real CPU/memory/network via Mach) +
  `SparklineView` / `HistoryGraphView` AppKit graphs + SwiftUI wrappers.
- **W7 `ProcexpSigning`** — `CodeSignProvider` (Security framework code signing, SHA-256,
  Keychain-backed VirusTotal v3 client with cache + rate limiting).
- **W9 `ProcexpNetwork`** — `NetworkProvider` (per-process sockets via proc_pidfdinfo) +
  best-effort IOKit GPU utilization.
- **W12 `ProcexpAutostart`** — `AutostartProvider` (launchd plist scan + login-item heuristic).
- **W8 `ProcexpActions`** — process action layer (kill/kill-tree/suspend/resume/nice/restart/
  bring-to-front) with privilege-escalation seam and confirmation metadata.

### Release

`Scripts/build_release.sh` produces `build/ProcexpMac.dmg` (ad-hoc signed today);
`Scripts/sign_notarize.sh` adds Developer ID signing + notarization once a
certificate and credentials are supplied. See
**[docs/RELEASE.md](docs/RELEASE.md)** for the full end-to-end process.


## Build & validate

This repo is a SwiftPM package. All engine libraries build with Command Line Tools:

```
swift build              # builds all library targets
swift run ProcexpSmoke   # validates W0 mock + live providers against this machine
```

> Note: the GUI app target and `xcodebuild`/notarization require **full Xcode**, and the
> unit-test targets require XCTest/swift-testing (Xcode). The `ProcexpSmoke` executable
> exists to validate the engines in a CLT-only environment.


## Documentation

- **[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)** — architecture, feature map,
  privilege model, workstream breakdown, milestones, risks.
- **[docs/DATA_CONTRACTS.md](docs/DATA_CONTRACTS.md)** — the frozen shared types & protocols
  all workstreams build against (ship first as `ProcexpModel`).
- **[docs/SUBAGENT_DISPATCH.md](docs/SUBAGENT_DISPATCH.md)** — ready-to-hand-off briefs and
  dispatch order for parallel development.

## Tech stack

Swift 5.9+, macOS 13+ (Ventura), hybrid AppKit (`NSOutlineView` process tree, custom graph
views) + SwiftUI (chrome, Preferences, Properties, System Information). Sampling via
`libproc`/`sysctl`; privileged data via a root `SMAppService` helper over XPC.

## Build (once scaffolding lands)

```
open ProcexpMac.xcodeproj
```
