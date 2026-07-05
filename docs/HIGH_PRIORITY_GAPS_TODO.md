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

## Detailed Information Additions Identified 2026-07-04

Reviewed against Windows Process Explorer `PINFO` / `ThreadsView` and public macOS `libproc`, `sysctl`, Mach, Security.framework, and ServiceManagement surfaces.

1. `[~]` Thread detail parity
   - Current fix: public `PROC_PIDLISTTHREADS` + `PROC_PIDTHREADINFO` now populates accessible thread TID, CPU, CPU time, run state, and base priority; helper uses `THREAD_EXTENDED_INFO` when task ports are available.
   - Add next: thread name (`pth_name`), current priority (`pth_curpri`), max priority (`pth_maxpriority`), scheduler policy (`pth_policy`), sleep time (`pth_sleep_time`), flags (`TH_FLAGS_*`), and dispatch queue address (`THREAD_IDENTIFIER_INFO.dispatch_qaddr`).
   - Possible with helper only: sampled stack/current PC and symbolized module/function. True original start address is not exposed as cleanly as Windows `ThreadQuerySetWin32StartAddress`.
   - Not available publicly: Windows wait reason, service tag/name, memory priority, I/O priority, and ideal processor equivalents.

2. `[ ]` More process-list counters from `proc_taskinfo`
   - Add columns/details for running thread count (`pti_numrunning`), page-ins (`pti_pageins`), copy-on-write faults (`pti_cow_faults`), Mach messages sent/received, Mach syscalls, Unix syscalls, existing-thread user/system time, and scheduler policy.
   - Add deltas/rates for page faults, context switches, syscalls, messages, disk read/write bytes, and total I/O bytes to match the Windows delta-column spirit.

3. `[ ]` Richer memory detail via helper task APIs
   - Use `task_vm_info` / `mach_task_basic_info` where permitted for physical footprint, internal/external/compressed/reusable/purgeable memory, page table bytes, resident peak where available, and per-process memory pressure color cues.
   - Extend mapped-image rows with VM protections, max protections, share mode, dirty/private/shared page estimates, and region path/type from `PROC_PIDREGIONINFO` / `PROC_PIDREGIONPATHINFO`.

4. `[ ]` Expanded file-descriptor and socket detail
   - For vnode fds, show open flags/access mode, offset, vnode type, device/inode, file size, and mount path when available from `vnode_fdinfowithpath` / `stat`.
   - For sockets, show fd number, socket kind, family, protocol, TCP state, local/remote names, and queue/option metadata where public `socket_fdinfo` exposes it.
   - Consider `PROC_PIDLISTFILEPORTS` as a file-port analog for handle-like resources.

5. `[ ]` macOS-native identity, app, and launchd metadata
   - Add process architecture/universal slice, bundle path, bundle ID, team ID, cdhash, code-directory flags, notarization/assessment result, hardened runtime flags, sandbox container path, and entitlement summary as selectable columns where inexpensive.
   - Add launchd label/domain, plist path, Program/ProgramArguments, MachServices, KeepAlive, RunAtLoad, login-item heuristic source, and parent launchd relationship.
   - Add window/app metadata where Accessibility/CoreGraphics permits it: main window title, visible/minimized state, activation policy, frontmost/regular/background app classification.

6. `[!]` Private or Windows-only parity gaps
   - Per-process network byte rates are private on macOS (`nettop`/ntstat path); keep sockets public and leave byte-rate columns unsupported unless a private-provider mode is explicitly added.
   - Per-process GPU utilization and GPU memory are not public. System GPU utilization remains best-effort via IOKit/Metal.
   - Windows-only columns such as GDI/User objects, jobs, exact integrity levels, UAC virtualization, DPI awareness, CET/CFG/DEP equivalents, .NET runtime counters, and Windows service tags should stay hidden or be replaced with macOS-native concepts.

## Dispatch Notes

- Run UI workstreams sequentially and validate with `xcodegen generate && xcodebuild -scheme ProcexpMac -configuration Debug build` after each substantial edit.
- Preserve existing user/worktree changes; do not reset the repo.
- Prefer existing app patterns: SwiftUI shell, AppKit dense tables, `AppModel` for shared persisted state, `SettingsStore` for user defaults.
