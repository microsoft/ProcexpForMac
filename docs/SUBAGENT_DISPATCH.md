# Subagent Dispatch Guide

Ready-to-hand-off briefs for parallel development. **Dispatch order:** run **W0 alone
first**, then dispatch Phase-1 workstreams concurrently, then Phase-2.

Every brief must include this preamble:

> You are building part of **Process Explorer for macOS** (native Swift port of Sysinternals
> Process Explorer). Read [docs/IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) and
> [docs/DATA_CONTRACTS.md](DATA_CONTRACTS.md) first. Build **only** against the contracts in
> `ProcexpModel`. Do not modify shared contracts without flagging it. Ship unit tests and
> graceful unavailable-state handling. Target macOS 13+, Swift 5.9+.

---

## Phase 0 — dispatch alone

- **W0 — ProcexpModel**: Implement all types and protocols from DATA_CONTRACTS.md.
  Deliverable: a Swift package that compiles, is `Sendable`-clean, and has tests covering
  identity, snapshot diffing, tree building, formatting, and color priority.

## Phase 1 — dispatch concurrently (all depend only on W0)

| WS | One-line task | Primary macOS APIs |
|----|---------------|--------------------|
| W1 | `LibprocDataProvider` — real process sampling | `libproc`, `sysctl KERN_PROC`, `proc_pid_rusage` |
| W2 | Root helper + XPC client, `SMAppService` install flow | `ServiceManagement`, `NSXPCConnection`, `task_for_pid` |
| W3 | Main window tree table (`NSOutlineView` bridge), columns, colors, toolbar, status bar | AppKit, SwiftUI |
| W4 | `SparklineView`, `HistoryGraphView`, System Information window, `SystemStatsProvider` | `host_processor_info`, `host_statistics64`, CoreAnimation/Metal |
| W5 | Lower pane: mapped-images + fd/port lists | `proc_pidinfo(PROC_PIDREGIONPATHINFO/PROC_PIDLISTFDS)` |
| W6 | Process Properties tabbed window | SwiftUI + W4/W7/W9 |
| W7 | `CodeSignProvider` + VirusTotal client (Keychain key, cache) | `SecStaticCode`, `SecCode*`, VT v3 API |
| W9 | `NetworkProvider` (sockets) + best-effort GPU stats | `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, IOKit `IOAccelerator` |
| W11 | Preferences window + settings/color/column-set persistence | `UserDefaults`, SwiftUI |
| W12 | `AutostartProvider` (launchd/login items) | plist scan, `SMAppService` |

## Phase 2 — dispatch after Phase-1 integration

| WS | One-line task |
|----|---------------|
| W8 | Process actions: kill/kill-tree/suspend/resume/priority/restart/bring-to-front |
| W10 | Menu-bar `NSStatusItem` mini CPU/IO/GPU history icon + minimize behavior |
| W13 | Entitlements, hardened runtime, Developer ID signing, notarization, DMG, About box, app icon, first-run helper UX |

---

## Interface ownership (avoid merge conflicts)

- Only **W0** edits `Packages/ProcexpModel`.
- Each workstream owns its own package/folder (see plan §2 layout). No two workstreams edit
  the same file. The App target's `AppModel` wiring is owned by **W3** (with W11 for settings).
- Provider conformances are injected in one place (App target composition root, owned by W3).

## Definition of done (every workstream)

1. Compiles in the Xcode project and as a standalone package. 2. Unit tests pass.
3. No fake/demo data paths in production UI. 4. No main-thread blocking; no leaks
(Instruments-clean). 5. Public API documented. 6. Graceful degradation when a capability or
the helper is unavailable.
