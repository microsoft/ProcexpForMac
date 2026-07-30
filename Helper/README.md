# ProcexpHelper — privileged root helper (W2) + embedding steps (W13)

This directory holds the privileged root daemon design artifacts. The daemon
**source** lives in `Sources/ProcexpHelper/` (SPM executable target); the
**client** that talks to it lives in `Sources/ProcexpPrivileged/`.

The helper is embedded by `Scripts/embed_helper.sh` for release builds and by
`Scripts/dev_install_helper.sh` for local elevated-path testing. Plain Xcode
builds omit it. `SMAppService` requires a stable signing identity: production
uses Developer ID, while the local workflow creates a persistent self-signed
identity and asks for separate user approval.

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
  peer's `SecCode` and runs `SecCodeCheckValidity`. Debug builds accept an
  intact ad-hoc signature for local testing; Release builds require the
  official app identifier and Microsoft Developer ID Team ID.

The two installable flavors use separate identities throughout:

| Flavor | App bundle ID | Helper / launchd / Mach service ID |
|---|---|---|
| Development | `com.sysinternals.procexpmac.dev` | `com.sysinternals.procexpmac.dev.helper` |
| Official | `com.sysinternals.procexpmac` | `com.sysinternals.procexpmac.helper` |

`HelperConstants` chooses the matching service from the running app's bundle
ID. The development launchd plist passes the same flavor to the standalone
daemon process.

## W13 — embedding the helper into the app bundle

1. **Build the SPM `ProcexpHelper` executable product.** The embedding script
  renames the output to the helper ID for the selected flavor.

2. **Copy the executable** into the app at build time via a *Copy Files* build
   phase on the app target:
   - Destination: **Wrapper**
   - Subpath: `Contents/Library/LaunchDaemons`
   - File: the `com.sysinternals.procexpmac.helper` executable.

3. **Generate the embedded launchd plist** from
  `com.sysinternals.procexpmac.helper.plist` (in this directory), replacing
  its identity fields together for development builds, and copy it into the
  same folder:
   - Destination: **Wrapper**
   - Subpath: `Contents/Library/LaunchDaemons`

4. **Sign both** with the same Developer-ID Team:
   - App entitlement: `Helper/ProcexpMac.entitlements`
     (`com.apple.developer.service-management.managed-by-launchd`).
   - Helper entitlement: `Helper/ProcexpHelper.entitlements`
     (`com.apple.security.cs.debugger` — allows `task_for_pid` under the
     Hardened Runtime).
   - Enable **Hardened Runtime** on both. Release builds enable it in
     `project.yml`; the helper signing scripts pass `--options runtime`.

5. **Keep the production pinning aligned with the signing identity:**
   - The plist sets `AssociatedBundleIdentifiers` to
     `com.sysinternals.procexpmac`.
   - `PeerValidation.swift` reads the helper's Team ID from its own code
     signature and requires the app to have that same Team ID plus the
     `com.sysinternals.procexpmac` identifier.

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

An ad-hoc build can run without the helper but cannot register it. Use
`Scripts/dev_install_helper.sh` for the persistent self-signed development
tuple, or pass a Developer ID identity to that script for the official tuple.
The two launchd labels can coexist and are removed independently by
`Scripts/dev_uninstall_helper.sh`.
