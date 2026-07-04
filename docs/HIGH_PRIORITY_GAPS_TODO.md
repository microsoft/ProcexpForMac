# High Priority Windows Parity Gaps

Tracked against the Windows Process Explorer source in `../ProcExp/exe`.

## Status Legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Implemented and locally validated
- `[!]` Blocked or partially possible on macOS

## Work Queue

1. `[x]` Column management parity
   - Add a real Select Columns dialog for the process list.
   - Add named column sets: save, load, organize/delete, and persistence.
   - Preserve the pinned Process column.
   - Validate with Debug app build.

2. `[x]` Lower pane Threads mode
   - Add a third lower-pane mode: DLLs / Handles / Threads.
   - Show per-process thread rows using available `ThreadInfo`.
   - Degrade clearly when only unprivileged stub thread detail is available.
   - Wire menu shortcut parity where practical.
   - Validated with Debug app build.

3. `[x]` Target-window process picker
   - Implement toolbar target/crosshair behavior to identify a process from a window under the pointer.
   - Use macOS Accessibility/Window APIs where possible.
   - Provide a clear permission/unavailable path if Accessibility access is required.
   - Implemented with a toolbar target button, one-click global picker, CoreGraphics window PID hit testing, Accessibility fallback when already authorized, and clear alerts for permission/unavailable cases.

4. `[x]` Better unavailable-state explanations
   - Distinguish empty lists from permission/API-limited results for images, handles, and TCP/IP.
   - Avoid implying a process has no resources when macOS refused enumeration.
   - Implemented with ownership/protection/provider heuristics in the lower pane and TCP/IP properties tab; validated with Debug app build.

5. `[x]` Process and image actions parity
   - Add Search Online for process and image rows.
   - Add Check VirusTotal commands to process and image context/menu paths.
   - Reuse existing signing/VirusTotal providers.
   - Implemented via process context/native menus, lower-pane DLL row context menu, and image detail actions; VirusTotal uses the existing signing provider and reports missing API key/no-result states.

6. `[x]` Dump/sample action
   - Add macOS equivalent of Create Minidump / Full Dump.
   - Candidate options: `sample`, `spindump`, or core-dump style capture.
   - Keep permissions and output-location UX explicit.
   - Implemented as `Sample Process…` in the native Process menu and process row context menu. Uses an explicit `NSSavePanel` destination and runs `/usr/bin/sample <pid> 10 -file <path>` asynchronously, reporting success/failure and permission-denied guidance through the process action alert.

7. `[x]` Richer Security tab
   - Add entitlements, hardened runtime, sandbox details, Team ID, signing authority, uid/gid/groups where available.
   - Keep platform-specific wording instead of Windows integrity terminology when not applicable.
   - Implemented with macOS-native Identity, Code Signing, Entitlements, and Sandbox / Runtime sections. Uses libproc/POSIX account/group lookups for uid/gid display, clearly labels current-process supplementary groups, extracts entitlements via Security.framework, and reports hardened runtime from code-signing flags as best-effort.

## Dispatch Notes

- Run UI workstreams sequentially and validate with `xcodegen generate && xcodebuild -scheme ProcexpMac -configuration Debug build` after each substantial edit.
- Preserve existing user/worktree changes; do not reset the repo.
- Prefer existing app patterns: SwiftUI shell, AppKit dense tables, `AppModel` for shared persisted state, `SettingsStore` for user defaults.
