# ProcexpHelper — privileged root helper (W2) + embedding steps (W13)

This directory holds the privileged root daemon design artifacts. The daemon
**source** lives in `Sources/ProcexpHelper/` (SPM executable target); the
**client** that talks to it lives in `Sources/ProcexpPrivileged/`.

The helper is **code-complete and compiling**. It is *not* wired into the app
bundle yet because embedding + registering an `SMAppService` daemon only
succeeds once the app is **Developer-ID signed** (workstream **W13**). Under the
current ad-hoc ("Sign to Run Locally") signature, `SMAppService.register()`
fails; the app detects this and stays on the unprivileged `LibprocDataProvider`
(see `App/AppModel.swift`).

## Architecture

```
 ┌────────────── ProcessExplorer.app ──────────────┐
 │  AppModel                                        │
 │    ├─ LibprocDataProvider   (unprivileged, W1)   │
 │    └─ PrivilegedDataProvider (client, W2) ───────┼──NSXPCConnection(.privileged)──┐
 └──────────────────────────────────────────────────┘                                │
                                                                                      ▼
                       ┌──────── Contents/Library/LaunchDaemons/ ────────┐   mach service
                       │  com.sysinternals.procexpmac.helper (root)      │  "com.sysinternals
                       │    NSXPCListener → HelperService                 │   .procexpmac.helper"
                       │      • snapshot()      → LibprocDataProvider     │
                       │      • threads()       → ThreadSampler           │
                       │        (task_for_pid + thread_info)              │
                       │      • modules/fds/env/cwd/strings → Libproc     │
                       │      • sendSignal/setNice (root → any process)   │
                       │    PeerValidation (SecCode) gate on connect      │
                       └─────────────────────────────────────────────────┘
```

- **Transport:** `NSXPCConnection` with `options: .privileged` to the mach
  service `com.sysinternals.procexpmac.helper`. Payloads cross as JSON `Data`
  (Codable DTOs in `Sources/ProcexpPrivileged/PrivilegedDTO.swift`), so the only
  classes on the wire are `NSData`/`NSString`/`NSNumber`/`NSError`.
- **Reuse:** the daemon delegates most work to `LibprocDataProvider`'s public
  API — as root, the same libproc/sysctl calls return cross-user data. Only the
  genuinely privileged bit (real per-thread CPU/state via `task_for_pid`) is new
  code, in `ThreadSampler.swift`.
- **Peer validation:** `PeerValidation.isTrusted(_:)` resolves the connecting
  peer's `SecCode` and runs `SecCodeCheckValidity`. It is lenient (logs + allows)
  under ad-hoc; W13 flips it to a hard `SecRequirement` pin (see below).

## W13 — embedding the helper into the app bundle

1. **Add an Xcode target** for the helper (either a "Command Line Tool" target
   built from `Sources/ProcexpHelper`, or reference the SPM `ProcexpHelper`
   product). Product name must be `com.sysinternals.procexpmac.helper`.

2. **Copy the executable** into the app at build time via a *Copy Files* build
   phase on the app target:
   - Destination: **Wrapper**
   - Subpath: `Contents/Library/LaunchDaemons`
   - File: the `com.sysinternals.procexpmac.helper` executable.

3. **Copy the launchd plist** `com.sysinternals.procexpmac.helper.plist`
   (in this directory) into the same folder:
   - Destination: **Wrapper**
   - Subpath: `Contents/Library/LaunchDaemons`

4. **Sign both** with the same Developer-ID Team:
   - App entitlement: `Helper/ProcexpMac.entitlements`
     (`com.apple.developer.service-management.managed-by-launchd`).
   - Helper entitlement: `Helper/ProcexpHelper.entitlements`
     (`com.apple.security.cs.debugger` — allows `task_for_pid` under the
     Hardened Runtime).
   - Enable **Hardened Runtime** on both (currently `ENABLE_HARDENED_RUNTIME: NO`
     in `project.yml`).

5. **Uncomment the pinning keys:**
   - In the plist: `AssociatedBundleIdentifiers` → `com.sysinternals.procexpmac`.
   - In `PeerValidation.swift`: build a `SecRequirement` such as
     `anchor apple generic and identifier "com.sysinternals.procexpmac" and
      certificate leaf[subject.OU] = "<TEAMID>"`, and change `lenientAllow`
     to return `false`.

6. **Registration** then works: the app's `Install Privileged Helper…` menu item
   calls `SMAppService.daemon(plistName:).register()`. The user approves the
   daemon in *System Settings ▸ General ▸ Login Items & Extensions*, after which
   `PrivilegedDataProvider.isHelperInstalled()` returns `true` and the app adopts
   the privileged provider automatically on next launch (or immediately, on a
   successful install).

## Files

| File | Purpose |
|---|---|
| `com.sysinternals.procexpmac.helper.plist` | launchd plist embedded under `Contents/Library/LaunchDaemons/`. |
| `ProcexpHelper.entitlements` | Helper signing entitlements (debugger → `task_for_pid`). |
| `ProcexpMac.entitlements` | App signing entitlement (`managed-by-launchd`). |

## Testing note

Do **not** attempt to `register()`/run the daemon under ad-hoc signing — it will
not launch. The whole path is exercised end-to-end only after W13 signing.
