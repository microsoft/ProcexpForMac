# UX Overhaul Plan — match Windows Process Explorer

Goal: make the macOS app **look and behave like Sysinternals Process Explorer**, based on a
fresh review of the Windows source (`../ProcExp`). This plan captures the full inventory and
splits the work into sequential workstreams (R1–R6) for subagents. All work is in the **App**
target; the engine packages (`Sources/*`) stay unchanged unless noted.

## Reference layout (top → bottom)
1. **Toolbar**: icon buttons + embedded live mini history graphs (CPU, Memory, I/O).
2. **Process tree**: left **frozen** process/name column (does NOT scroll horizontally); all
   other columns scroll horizontally to its right. Vertical scroll + selection shared.
3. **Lower pane** (closeable): DLL (mapped images) view or Handle (fd/port) view.
4. **Status bar**: CPU %, commit, process/thread/handle counts, etc.

## Windows menu tree (mirror as native macOS menus)
- **File**: Run… (⌘R), Save (⌘S), Save As… (⌘⇧S), Shutdown ▸ (Logoff/Shutdown/Restart), Exit.
- **Options**: Run At Logon, Verify Image Signatures, VirusTotal ▸ (Check / Submit Unknown),
  Always On Top, Hide When Minimized, Allow Only One Instance, Confirm Kill, Highlight
  Relocated DLLs, Tray Icons ▸ (CPU/I-O/Commit/Phys History), Difference Highlight Duration…,
  Font…, Theme ▸ (Light/Dark/System).
- **View**: Show Process Tree (⌘T), Show Column Heatmaps, Scroll to New Processes, Show
  Unnamed Handles and Mappings, Show Processes From All Users, Show Lower Pane (⌘L), Lower
  Pane View ▸ (DLLs ⌘D / Handles ⌘H / Threads ⌘Y), Refresh Now (F5), Update Speed ▸
  (.5s/1s/2s/5s/10s/Paused Space), Organize/Save/Load Column Sets, Select Columns….
- **Process** (also right-click context): Window ▸ (Bring to Front/Restore/Minimize/Maximize/
  Close), Set Priority ▸ (Realtime/High/Above/Normal/Below/Idle), Kill Process (Del), Kill
  Process Tree (⇧Del), Restart, Suspend/Resume, Create Dump ▸ (Mini/Full), Check
  VirusTotal.com, Properties…, Search Online… (⌘M).
- **Find**: Filter Processes… (⌘F), Find Handle or DLL… (⌘⇧F).
- **Help**: Help (F1), About.

## Toolbar buttons (order, with Windows icons in ../ProcExp/exe/icons)
Save (save.ico) · Refresh (refresh.ico) · **[CPU history graph][Memory history graph][I/O
history graph]** · System Information (sysinfo.ico) · Show Process Tree toggle (tree.ico) ·
Process Properties (process-properties.ico) · Kill Process (delete.ico) · Show Lower Pane
toggle (split.ico) · DLL view / Handle view toggle (dll.ico / view-handles.ico) · Find
(find.ico) · **Target crosshair** drag-to-select-window (target.ico).

## Columns (add the missing ones, incl. graph columns)
Present: Process, PID, CPU, Private Bytes, Working Set, Description, Company, Verified Signer.
**Add**: **CPU History** (sparkline column), **Private Bytes History** (sparkline),
**I/O History** (sparkline), Virtual Size, Peak/WS-Private/WS-Shared, Page Faults + Delta,
Priority / Base Priority, Threads, Handles, Context Switches, Cycles, Image Type (32/64/arm64),
Integrity/Sandbox, User Name, Session/TTY, Start Time, Command Line, Path, Version,
I/O Reads/Writes/Delta bytes, Network Send/Recv/Delta, GPU %, GPU History, Autostart Location,
VirusTotal. Support per-column show/hide (Select Columns…) + heatmap shading option.

## Process Properties tabs (Windows order; Image first)
**Image** · **Performance** · **Performance Graph** (per-process CPU / Private Bytes / I-O
graphs) · **Threads** · **TCP/IP** · **Security** · **Environment** · **Strings**.
Image tab must include: icon, description, company, version, build time, path, autostart
location, command line, current directory, parent, user, started time, image type, mitigation
flags (Hardened Runtime / Library Validation / ASLR — macOS analogs of DEP/ASLR), and buttons:
**Bring to Front, Kill Process, Verify (signature), VirusTotal, Explore (reveal in Finder)**.

## DLL / Handle detail windows (NEW)
- Lower-pane rows are selectable and **double-click opens a detail window**:
  - **DLL/Image properties**: path, name, description, company, version, signer/notarization,
    load address, mapped size, VirusTotal, "Reveal in Finder".
  - **Handle/Object details**: fd number, type (vnode/socket/kqueue/…), name/path or addr:port,
    and any available attributes.

## System Information graphs (NEW behavior)
Each graph records the **top consumer** of that resource per sample; hovering the graph shows
a tooltip with the process name + value at that time position (like Procexp's graph tooltips).

---

# Workstreams (sequential — all edit the App target)

- **R1 — Menus, toolbar, icons, actions.** Full native menu bar mirroring the tree above with
  shortcuts; toolbar of icon buttons using the **converted Windows icons** (convert
  `../ProcExp/exe/icons/*.ico` → PNG imagesets in `App/Assets.xcassets`; fall back to SF
  Symbols per button if conversion unavailable) + embedded live mini CPU/Mem/I-O graphs; wire
  Run/Save/Pause/Refresh/Tree/LowerPane/Find/Properties/Kill actions to `AppModel`.
- **R2 — Frozen first column + graph columns + Procexp styling.** Rework the main tree so the
  Process/name column is frozen (two synchronized AppKit views: outline for the name column +
  a horizontally-scrolling table for data columns, shared vertical scroll + selection + row
  colors). Add CPU/PrivateBytes/I-O **history sparkline columns** (per-pid rings in the
  coordinator). Compact rows, gridlines, header context menu for Select Columns.
- **R3 — Lower pane rework + DLL/Handle detail windows.** Closeable lower pane toggled by the
  toolbar DLL/Handle buttons + ⌘L; rows selectable; double-click opens the DLL-properties or
  Handle-details window.
- **R4 — Process Properties: Windows-style tabs.** Reorganize to Image/Performance/Performance
  Graph/Threads/TCP-IP/Security/Environment/Strings with the exact per-tab fields + Image-tab
  buttons; add the per-process Performance Graph tab.
- **R5 — System Information top-consumer tooltips.** Track per-sample top process per resource;
  hover tooltip on each graph.
- **R6 — Visual polish pass.** Match Procexp density/spacing/fonts/status bar; verify against
  the reference screenshot; light/dark theming.
