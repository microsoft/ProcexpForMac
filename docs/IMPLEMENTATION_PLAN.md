# Process Explorer for macOS — Master Implementation Plan

> Goal: An **idiomatic native macOS** application that reproduces the look, feel, and
> equivalent functionality of Sysinternals **Process Explorer** (Windows), based on the
> Windows source in `../ProcExp`.

This document is the coordination hub for a **parallelized build**. It defines the
architecture, the shared contracts every workstream depends on, and self-contained
**workstream specs** that can each be handed to an independent subagent.

---

## 1. Product definition — what "equivalent functionality" means

Process Explorer's Windows feature set, and its idiomatic macOS equivalent:

| # | Windows Procexp feature | macOS equivalent | Notes |
|---|---|---|---|
| 1 | Process **tree** list with live refresh, difference highlighting (new=green, dead=red) | `NSOutlineView` tree, timed refresh, row fade animation | Core UX |
| 2 | Rich, user-selectable **columns** (CPU, Private Bytes, Working Set, PID, Description, Company, Threads, Handles, Priority, I/O, Network, GPU, …) + **column sets** | Same columns mapped to macOS metrics | See §4 column map |
| 3 | Per-row **CPU sparkline** + color coding (own/services/suspended/new/packed/immersive) | Custom cell drawing + row background colors | |
| 4 | **Lower pane**: DLL view / Handle view (toggle) | Mapped-images view / File-descriptor & Mach-port view | |
| 5 | **Process Properties** multi-tab window (Image, Performance, Perf Graph, Threads, TCP/IP, Security, Environment, Strings, GPU, .NET, Job) | Native tabbed inspector, subset applicable to macOS | See §5 |
| 6 | **System Information** window: CPU/Memory/I/O/GPU/Network history graphs | Custom graph views fed by host stats | |
| 7 | **Find handle/DLL** search | Search across fds/mapped images | |
| 8 | **Kill / Kill tree / Suspend / Resume / Set priority / Set affinity** | `kill`, `SIGSTOP/SIGCONT`, `setpriority`, affinity N/A on macOS (see notes) | |
| 9 | **Signature verification** (Authenticode) + **VirusTotal** hash lookup | macOS **code signing** (Developer ID / Team ID / notarization) + VirusTotal | |
| 10 | **Menu-bar (tray) mini CPU/IO/GPU history icons**, minimize-to-tray | `NSStatusItem` menu-bar graphs | |
| 11 | **Replace Task Manager**, run as admin, mini-view | Elevated **privileged helper** via `SMAppService` + XPC | |
| 12 | **Autostart location** column (Autoruns integration) | launchd (LaunchAgents/Daemons) + Login Items | |
| 13 | Save/print process list, config import/export | Export to text/JSON, settings persistence | |
| 14 | **Handle search / DLL search / process search** highlighting | Same | |

**Out of scope for v1 (Windows-only concepts with no clean macOS analog):** ETW,
.NET CLR performance counters (optional later), Job objects (map to nothing → hide),
"Replace Task Manager", UAC virtualization, GDI/USER object counts. GPU per-process is
**best-effort** (see W9 notes).

---

## 2. Architecture & technology decisions

**Language / frameworks (idiomatic macOS):**

- **Swift 5.9+**, targeting **macOS 13 Ventura** minimum (needed for `SMAppService`;
  macOS 14+ features used opportunistically).
- **UI: hybrid AppKit + SwiftUI.**
  - The main process **tree table** uses **AppKit `NSOutlineView`** (wrapped in
    `NSViewRepresentable`). Rationale: hundreds of rows refreshing 1–2×/sec with custom
    per-cell sparkline drawing, per-row background colors, incremental diffing, and column
    reordering/sizing are exactly what `NSOutlineView` does well and SwiftUI `Table`
    currently does not at this density.
  - **SwiftUI** for the app shell, menus, Preferences, Process Properties window, System
    Information window layout, dialogs, and the About box.
  - Graphs are **custom `NSView`/`CALayer`** (or Metal for the busy system graphs)
    wrapped for SwiftUI.
- **Concurrency:** Swift Concurrency (`async/await`, `actor`) for the sampling engine.
  Sampling runs off the main thread and publishes immutable snapshots.
- **Data flow:** unidirectional. A `SamplingEngine` **actor** produces immutable
  `ProcessSnapshot` values on a timer; the UI observes an `@Observable`
  `AppModel` that holds the latest snapshot + derived view state.

**Project layout:** Xcode app project at the root that composes local **Swift Packages**
(one per engine module) so workstreams compile/test independently.

```
ProcexpMac/
  ProcexpMac.xcodeproj
  App/                         # W3/W11 SwiftUI+AppKit app target
  Packages/
    ProcexpModel/              # W0 shared contracts (types + protocols)  <-- everyone depends on this
    ProcexpSampling/           # W1 libproc/sysctl sampling engine
    ProcexpPrivileged/         # W2 XPC client + helper protocol
    ProcexpHelper/             # W2 privileged helper tool target
    ProcexpSigning/            # W7 code signing + VirusTotal
    ProcexpNetwork/            # W9 per-process sockets
    ProcexpGraphs/             # W4 graph views
    ProcexpAutostart/          # W12 launchd/login items
  Helper/                      # W2 embedded helper bundle
  docs/
  Tests/
```

**Golden rule for parallelism:** everything is coded against the **protocols and value
types in `ProcexpModel` (W0)**. W0 ships first with a **`MockDataProvider`**, so UI,
graphs, and property-sheet workstreams build and run against mock data before the real
sampling engine exists.

---

## 3. Privilege model (the "driver" replacement)

Windows Procexp uses a kernel driver for privileged data. macOS equivalent:

- **Unprivileged path (default):** `libproc` + `sysctl` give a lot for the current user's
  processes and basic info for all processes (name, pid, ppid, uid, RSS/VSZ, start time,
  args for own processes, fds you own).
- **Privileged path (opt-in):** a **`SMAppService` daemon** (`ProcexpHelper`) runs as root
  and exposes an **XPC** interface. It performs `task_for_pid`-dependent sampling (accurate
  per-process CPU via `task_info`/`thread_info`, other users' args/env/cwd, full fd/port
  enumeration, per-thread stacks). UI degrades gracefully when the helper is not installed.
- Entitlements: `com.apple.security.get-task-allow` is **not** it; the helper needs to run
  as root (installed via `SMAppService.daemon`). The main app requests the user install the
  helper on first launch, mirroring Procexp's "Run as Administrator".

This is **W2** and is the highest-risk item — start it early, in parallel, behind the
`PrivilegedSampling` protocol so W1 can ship an unprivileged implementation first.

---

## 4. Column map (Windows → macOS metric & source API)

Define all columns in W0 as a `Column` enum. Sources:

| Column | macOS source |
|---|---|
| Process (name+icon) | `proc_name` / `kinfo_proc`; icon via `NSWorkspace.icon(forFile:)` on bundle path |
| PID / PPID | `kinfo_proc.kp_proc.p_pid` / `kp_eproc.e_ppid` |
| CPU % | Δ(user+system CPU time) / Δ wall×ncpu. Unpriv: `proc_pid_rusage(RUSAGE_INFO_V*)` (own) / helper `task_info(TASK_BASIC_INFO)+thread times` (all) |
| CPU Time (total) | `ri_user_time+ri_system_time` (rusage) |
| Private Bytes / Working Set | `proc_pidinfo(PROC_PIDTASKINFO)` → `pti_resident_size`, phys_footprint via `task_vm_info.phys_footprint` (helper) |
| Virtual Size | `pti_virtual_size` |
| Threads | `pti_threadnum` / `proc_pidinfo(PROC_PIDLISTTHREADS)` |
| Handles → **File Descriptors** | count from `proc_pidinfo(PROC_PIDLISTFDS)` |
| Description / Company | `CFBundle` Info.plist (CFBundleName, ... ) + code-sign Team/authority |
| Version | `CFBundleShortVersionString` |
| Image Path | `proc_pidpath` |
| Command Line | `sysctl KERN_PROCARGS2` |
| User (Owner) | `kp_eproc.e_ucred.cr_uid` → `getpwuid` |
| Session / TTY | `kp_eproc.e_tdev` |
| Start Time | `kp_proc.p_starttime` |
| Priority / Nice | `kp_proc.p_nice`; `getpriority` |
| I/O Read/Write Bytes & Delta | `proc_pid_rusage` → `ri_diskio_bytesread/written` |
| Network Send/Recv | per-socket byte counts (limited on macOS; see W9) |
| GPU % / GPU Memory | IOKit `IOAccelerator` / Metal counters — **best-effort** (W9 notes) |
| Integrity / Sandbox | App Sandbox flag, platform-binary, SIP status, `csops` flags |
| Signature (Verified) | `SecStaticCode` validity + authority (W7) |
| VirusTotal | SHA-256 hash lookup (W7) |
| Autostart Location | launchd/login-item match (W12) |

---

## 5. Process Properties tabs (macOS-applicable)

| Tab | Content | Source |
|---|---|---|
| **Image** | Path, description, company, version, code-sign authority, command line, cwd, start time, parent, user, "Verify" & "VirusTotal" buttons, icon | W1 + W7 |
| **Performance** | CPU time, threads, private/working set/virtual, fds, I/O bytes, page faults | W1 |
| **Performance Graph** | CPU / private bytes / I/O history spar-graphs for the process | W4 |
| **Threads** | Thread list: TID, CPU%, start address/symbol, state; suspend/kill thread | W2 (needs task port) |
| **TCP/IP** | Per-process sockets: proto, local/remote addr:port, state | W9 |
| **Environment** | Env vars | `KERN_PROCARGS2` (own) / helper |
| **Strings** | ASCII/Unicode strings from image (and memory via helper) | W1 |
| **Security** | uid/gid, groups, sandbox, entitlements, SIP/platform-binary, code-sign flags | W7 |
| **GPU** | GPU %, GPU memory (best-effort) | W9 |

(Windows-only tabs — Job, .NET, ETW — omitted in v1.)

---

## 6. Workstream breakdown & dependency graph

```
        ┌────────────────────────── W0 ProcexpModel (contracts + Mock) ──────────────────────────┐
        │ (BLOCKS ALL — ship first, ~small, one owner)                                            │
        └───────────────────────────────────────────────────────────────────────────────────────┘
             │            │            │            │            │            │            │
   ┌─────────┴──┐  ┌──────┴───┐  ┌─────┴────┐ ┌─────┴────┐ ┌─────┴────┐ ┌─────┴────┐ ┌─────┴────┐
   │ W1 Sampling│  │ W2 Priv  │  │ W3 Main  │ │ W4 Graphs│ │ W5 Lower │ │ W6 Props │ │ W7 Sign  │
   │  engine    │  │  helper  │  │  window  │ │          │ │  pane    │ │  window  │ │  +VTotal │
   └─────┬──────┘  └────┬─────┘  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
         │              │             │            │            │            │            │
         └──────────────┴─────────────┴────────────┴────────────┴────────────┴────────────┘
                                       │
          ┌─────────┬──────────┬───────┴────────┬───────────┬─────────────┐
     W8 Actions  W9 Network  W10 MenuBar    W11 Settings  W12 Autostart  W13 Packaging
```

- **Phase 0 (serial, ~1 unit):** W0 only.
- **Phase 1 (max parallelism):** W1, W2, W3, W4, W5, W6, W7, W9, W11, W12 all run against W0 mocks.
- **Phase 2 (integration):** wire real providers into UI; W8 actions; W10 menu bar; W13 packaging/notarization; end-to-end polish.

Each workstream below is a **self-contained subagent brief**.

---

## 7. Workstream specs (subagent briefs)

Each spec lists: **Owns** (files), **Consumes** (contracts), **Produces** (contracts),
**Tasks**, **Acceptance**, **Key APIs/refs**. Full contract signatures live in
[docs/DATA_CONTRACTS.md](DATA_CONTRACTS.md).

### W0 — Shared model & contracts  *(do first; blocks everyone)*
- **Owns:** `Packages/ProcexpModel/*`
- **Produces:** `ProcessRecord` value type, `ProcessSnapshot`, `ThreadInfo`, `ModuleInfo`
  (mapped image), `FileDescriptorInfo`, `SocketInfo`, `SignatureInfo`, `SystemStats`,
  `HistoryRing<T>`, `Column` enum + formatting, `ProcessColorRule`, and the protocols:
  `ProcessDataProviding`, `PrivilegedSampling`, `SigningProviding`, `NetworkProviding`,
  `SystemStatsProviding`, plus `MockDataProvider` conforming to all of them with realistic
  fake data + a synthetic tree.
- **Tasks:** define types (Codable where useful), define protocols, implement mock,
  unit-test mock snapshots, document invariants (identity = pid+starttime).
- **Acceptance:** all packages/targets can `import ProcexpModel`; mock produces a stable,
  animatable tree of ~150 fake processes with moving CPU/memory values.

### W1 — Sampling engine (unprivileged)  *(core)*
- **Owns:** `Packages/ProcexpSampling/*`
- **Consumes:** W0 protocols. **Produces:** `LibprocDataProvider: ProcessDataProviding`.
- **Tasks:** enumerate via `sysctl KERN_PROC_ALL` / `proc_listallpids`; per-pid fill from
  `proc_pidinfo(PROC_PIDTASKINFO/PROC_PIDT_SHORTBSDINFO)`, `proc_pid_rusage`,
  `proc_pidpath`, `KERN_PROCARGS2` (args/env/cwd), fd list & count, build parent/child tree,
  compute CPU% via snapshot deltas, icon resolution, string extraction for Strings tab.
  Actor-based timer; emit immutable snapshots; graceful per-pid failures.
- **Acceptance:** live tree of real processes at 1s cadence, CPU% within ~1% of Activity
  Monitor for user processes; no main-thread work; instruments-clean (no leaks).
- **Key APIs:** `<libproc.h>`, `sys/sysctl.h`, `proc_pid_rusage`, `mach_timebase_info`.

### W2 — Privileged helper + XPC  *(high risk; start early)*
- **Owns:** `Packages/ProcexpPrivileged/*`, `Packages/ProcexpHelper/*`, `Helper/`
- **Consumes:** W0. **Produces:** `PrivilegedDataProvider: PrivilegedSampling` (client) and
  the root helper implementing accurate CPU (`task_info`/`thread_info`), all-user args/env,
  full fd/port enumeration, per-thread info & stacks, memory `task_vm_info.phys_footprint`.
- **Tasks:** `SMAppService.daemon` register/unregister UI flow; signed XPC with code-signing
  requirement pinning; async API mirroring `ProcessDataProviding`; fall back to W1 when
  absent; thorough error/timeout handling; `task_for_pid` usage guarded.
- **Acceptance:** with helper installed, CPU%/threads/env for **other users'** processes
  populate; uninstall cleanly; XPC peer identity validated.
- **Key APIs:** `ServiceManagement`, `NSXPCConnection`, `task_for_pid`, `proc_pidinfo`.

### W3 — Main window (tree table)  *(core UX)*
- **Owns:** `App/MainWindow/*` (NSOutlineView bridge, columns, toolbar, status bar).
- **Consumes:** W0 (`ProcessSnapshot`, `Column`, `ProcessColorRule`), W4 sparkline cell, W5 lower pane host, W8 action commands.
- **Tasks:** `NSOutlineView` tree bound to snapshot; incremental diffing (stable identity),
  new/dead row highlight + fade; column show/hide/reorder/resize + **column sets** persisted;
  sorting; row colors (own/service/suspended/new/packed/sandboxed); CPU sparkline cell;
  toolbar (refresh rate, find, sysinfo, kill, properties, DLL/handle toggle); status bar
  (CPU/commit/process totals); context menu; search-highlight; splitter to lower pane.
- **Acceptance:** feels like Procexp — smooth 1–2s refresh, no flicker, correct tree
  expand/collapse persistence, columns configurable, colors match legend.

### W4 — Graphs & System Information window
- **Owns:** `Packages/ProcexpGraphs/*`, `App/SystemInfo/*`
- **Consumes:** W0 `HistoryRing`, `SystemStats`. **Produces:** reusable `SparklineView`,
  `HistoryGraphView`, and the System Information window (CPU total + per-core, Memory,
  I/O, GPU, Network tabs) with tooltips-on-hover showing the process at that time.
- **Tasks:** CoreAnimation/Metal graph rendering; per-cell sparkline used by W3;
  `SystemStatsProviding` impl using `host_processor_info` + `host_statistics64(vm)`.
- **Acceptance:** graphs scroll smoothly at refresh cadence; visually match Procexp style.

### W5 — Lower pane (modules & descriptors)
- **Owns:** `App/LowerPane/*`
- **Consumes:** W0 `ModuleInfo`, `FileDescriptorInfo`, provider protocols.
- **Tasks:** DLL-equivalent **mapped images** list (`proc_pidinfo(PROC_PIDREGIONPATHINFO)` /
  dyld image list via helper) and **handle-equivalent** fd/Mach-port list
  (`proc_pidfdinfo`); columns, sorting, per-row diff highlight; toggle & follow selection.
- **Acceptance:** selecting a process shows its mapped dylibs / open fds; live updates.

### W6 — Process Properties window
- **Owns:** `App/Properties/*`
- **Consumes:** W0 types; W4 graphs; W7 signing; W9 sockets.
- **Tasks:** tabbed SwiftUI window per §5 (Image, Performance, Perf Graph, Threads,
  TCP/IP, Environment, Strings, Security, GPU); live-updating while open; Verify/VirusTotal
  buttons; per-thread actions.
- **Acceptance:** all applicable tabs populated for a selected process; updates live.

### W7 — Code signing & VirusTotal
- **Owns:** `Packages/ProcexpSigning/*`
- **Consumes:** W0. **Produces:** `CodeSignProvider: SigningProviding` + VirusTotal client.
- **Tasks:** `SecStaticCodeCreateWithPath` + `SecCodeCheckValidity` +
  `SecCodeCopySigningInformation` → authority chain, Team ID, Developer ID vs ad-hoc vs
  unsigned, notarization (`SecAssessment`/`spctl`-style), platform binary; SHA-256 hashing
  + VirusTotal v3 lookup with on-disk cache & rate limiting; async, cancellable.
- **Acceptance:** correct signer strings for system + third-party + unsigned binaries;
  VT results cached; no network on main thread; API key stored in Keychain.

### W8 — Process actions
- **Owns:** `App/Actions/*`
- **Consumes:** W0, W2 (for cross-user). **Produces:** command layer.
- **Tasks:** Kill (`kill SIGKILL`), Kill tree (recurse children), Suspend/Resume
  (`SIGSTOP/SIGCONT` or `task_suspend` via helper), Set priority (`setpriority`/renice),
  Restart, Bring window to front (`NSRunningApplication`), confirmations, privilege
  escalation prompts. (Affinity: macOS has no per-process CPU pinning API → hide/disable.)
- **Acceptance:** actions work for own processes unprivileged, cross-user via helper.

### W9 — Network & GPU (best-effort)
- **Owns:** `Packages/ProcexpNetwork/*`
- **Consumes:** W0. **Produces:** `NetworkProvider: NetworkProviding`, `GPUStatsProvider`.
- **Tasks:** per-process sockets via `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` → TCP/UDP v4/v6,
  local/remote, state; drive TCP/IP tab, Network column, network history. GPU per-process
  via IOKit `IOAccelerator` statistics / `IOReport` (best-effort; degrade to system GPU %
  if per-process unavailable).
- **Acceptance:** socket list matches `lsof -i` for a process; GPU shows something sane or
  hides gracefully.

### W10 — Menu-bar (tray) mini graphs & minimize behavior
- **Owns:** `App/MenuBar/*`
- **Consumes:** W0 history, W4 rendering.
- **Tasks:** `NSStatusItem` with live CPU (and optional I/O/GPU/mem) history icon; click →
  activate/toggle window; hide-dock-when-minimized option; tooltip = top CPU process.
- **Acceptance:** menu-bar icon animates with CPU load; matches Procexp tray behavior.

### W11 — Settings, persistence, appearance
- **Owns:** `App/Settings/*`, config store.
- **Consumes:** W0.
- **Tasks:** Preferences window (refresh rate, colors/legend editor, columns default,
  confirm-kill, verify-signatures, VT auto-submit, difference-highlight duration, opacity,
  always-on-top, symbol/dsym path); persist to `UserDefaults`/JSON; import/export config
  (parity with Procexp `/c`); light/dark + system accent; column-set storage.
- **Acceptance:** settings persist across launches; color legend live-applies to tree.

### W12 — Autostart detection
- **Owns:** `Packages/ProcexpAutostart/*`
- **Consumes:** W0. **Produces:** autostart location string per process.
- **Tasks:** scan LaunchAgents/LaunchDaemons (`/Library`, `~/Library`, `/System` read-only),
  `SMAppService` login items, cron; match running process → autostart source string for the
  Autostart column and Image tab.
- **Acceptance:** processes started by launchd show their plist path.

### W13 — Packaging, signing, notarization, About, icon
- **Owns:** entitlements, `Info.plist`, build config, CI, `App/About/*`, app icon assets.
- **Consumes:** all.
- **Tasks:** Xcode targets & entitlements (hardened runtime, helper embedding), Developer ID
  signing + notarization pipeline, DMG packaging, About box (version, credits mirroring
  Procexp), app icon (macOS style), crash/log plumbing, first-run helper-install UX.
- **Acceptance:** signed, notarized `.app` launches on a clean machine; helper installs.

---

## 8. Cross-cutting conventions

- **Process identity** = `(pid, startTime)` to survive pid reuse. All diffing keys on this.
- **Snapshots are immutable value types**; the engine never mutates published state.
- **No blocking on the main thread**; all sampling/signing/VT is `async` off-main.
- **Graceful degradation**: every privileged datum has an unprivileged fallback or "N/A".
- **Testing**: each package ships unit tests + a SwiftUI preview using `MockDataProvider`.
- **Accessibility & localization**: use `LocalizedStringKey`, VoiceOver labels on graphs.
- **Style**: match Procexp semantics but native macOS HIG (toolbar, SF Symbols, colors).

## 9. Suggested milestones

1. **M1 Skeleton:** W0 done; app runs on mock data showing a live fake tree (W3+W4 basic).
2. **M2 Real processes:** W1 wired; columns, sorting, colors, lower pane (W5), actions (W8).
3. **M3 Depth:** W6 properties, W7 signing+VT, W9 network, W2 helper for cross-user/CPU.
4. **M4 Polish/ship:** W10 menu bar, W11 settings, W12 autostart, W13 notarized release.

## 10. Risks & mitigations

- **task_for_pid privileges** → isolate in W2 helper; unprivileged fallback ships first.
- **Per-process GPU/network byte rates** are limited on macOS → mark best-effort, hide if empty.
- **SwiftUI Table perf** → use AppKit `NSOutlineView` for the main tree (decided).
- **Notarization/helper signing complexity** → own workstream (W13), start entitlements early.
