//
//  MainWindowView.swift
//  W3 — Main window composition: toolbar + process tree + status bar.
//

import SwiftUI
import AppKit
import ProcexpModel
import ProcexpGraphs

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var searchText: String = ""
    /// Focus for the search field so ⌘F / the Find button can jump to it.
    @FocusState private var searchFocused: Bool
    /// W8 — routes context-menu / toolbar commands to `ProcessActions` and
    /// drives the confirmation + error dialogs below. Shared with the menu bar
    /// via `AppModel` so both entry points use one flow.
    private var coordinator: ActionCoordinator { model.actionCoordinator }

    /// Refresh-rate choices (seconds) offered in the toolbar.
    private let refreshChoices: [TimeInterval] = [0.5, 1, 2, 5]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar
                .fixedSize(horizontal: false, vertical: true)
                .zIndex(1)

            if model.targetWindowPickerActive {
                targetPickerBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
            if model.showLowerPane {
                VSplitView {
                    processTree
                        .frame(minHeight: 180)
                    LowerPaneView()
                        .frame(minHeight: 130, idealHeight: 200)
                }
            } else {
                processTree
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 500)
        .sheet(isPresented: $model.showRunSheet) {
            RunProcessSheet()
        }
        .sheet(isPresented: $model.showSelectColumnsSheet) {
            SelectColumnsSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showSaveColumnSetSheet) {
            SaveColumnSetSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showOrganizeColumnSetsSheet) {
            OrganizeColumnSetsSheet()
                .environment(model)
        }
        .background(SpacePauseMonitor {
            model.togglePause()
        })
        .onChange(of: model.focusSearchToken) {
            searchFocused = true
        }
        .onChange(of: model.saveRequestToken) {
            saveProcessList()
        }
        .confirmationDialog(
            coordinator.pending?.confirmation.title ?? "",
            isPresented: Binding(
                get: { coordinator.pending != nil },
                set: { if !$0 { coordinator.cancel() } }
            ),
            presenting: coordinator.pending
        ) { pending in
            Button(
                pending.confirmButtonTitle,
                role: pending.confirmation.destructive ? .destructive : nil
            ) {
                coordinator.confirm(model: model)
            }
            Button("Cancel", role: .cancel) { coordinator.cancel() }
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .alert(
            coordinator.errorTitle,
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .alert(
            model.targetWindowPickerAlert?.title ?? "Window Picker",
            isPresented: Binding(
                get: { model.targetWindowPickerAlert != nil },
                set: { if !$0 { model.targetWindowPickerAlert = nil } }
            )
        ) {
            if model.targetWindowPickerAlert?.offersAccessibilitySettings == true {
                Button("Open Accessibility Settings") {
                    model.openAccessibilitySettingsForTargetPicker()
                }
            }
            Button("OK", role: .cancel) { model.targetWindowPickerAlert = nil }
        } message: {
            Text(model.targetWindowPickerAlert?.message ?? "")
        }
        .alert(
            model.processActionAlert?.title ?? "Process Action",
            isPresented: Binding(
                get: { model.processActionAlert != nil },
                set: { if !$0 { model.processActionAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.processActionAlert = nil }
        } message: {
            Text(model.processActionAlert?.message ?? "")
        }
    }

    /// The process tree, shared between the split and non-split layouts.
    private var processTree: some View {
        ProcessOutlineView(model: model,
                           snapshot: model.snapshot,
                           columns: model.columns,
                           colorRules: model.colorRules,
                           treeMode: model.showProcessTree,
                           searchText: searchText) { command, pid in
            handle(command, pid)
        }
    }

    // MARK: Toolbar

    /// Icon toolbar mirroring Windows Process Explorer: Save · Refresh · System
    /// Information · Show Process Tree · Properties · Kill · Lower Pane · Find,
    /// followed by the live, individually-resizable CPU/Memory/I-O mini graphs
    /// and the filter field.
    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            iconButton("save", tip: "Save the process list to a file… (⌘S)") {
                saveProcessList()
            }
            iconButton("refresh", tip: "Refresh now (F5)") {
                Task { await model.forceRefresh() }
            }

            toolbarDivider

            iconButton("sysinfo", tip: "System Information — live graphs (⌘I)") {
                model.systemInfoTab = .summary
                openWindow(id: SystemInfoWindow.id)
            }

            toolbarDivider

            iconToggle("tree", isOn: model.showProcessTree,
                       tip: "Show Process Tree (⌘T)") {
                model.showProcessTree.toggle()
            }
            iconButton("props", tip: "Process Properties…",
                       disabled: model.selection == nil) {
                if let pid = model.selection { openProperties(pid) }
            }
            iconButton("kill", tip: "Kill Process (Del)",
                       disabled: model.selection == nil) {
                if let pid = model.selection {
                    coordinator.request(.kill, pid: pid, model: model)
                }
            }

            toolbarDivider

            iconToggle("split", isOn: model.showLowerPane,
                       tip: "Show / hide the Lower Pane (⌘L)") {
                model.showLowerPane.toggle()
            }

            toolbarDivider

            iconButton("find", tip: "Find Handle or DLL… (⌘F)") {
                openWindow(id: FindHandleDLLWindow.id)
            }
            iconToggle("target", isOn: model.targetWindowPickerActive,
                       tip: "Find Window's Process") {
                model.toggleTargetWindowPicker()
            }

            toolbarDivider

            // Live, individually-resizable mini history graphs (CPU · Memory ·
            // I/O), placed to the right of all the icon buttons.
            resizableGraph(index: 0,
                           values: model.cpuHistory.values,
                           maxValue: 100,
                           color: RGBA(0, 200, 0),
                           tip: cpuTip,
                           systemInfoTab: .cpu)
            resizableGraph(index: 1,
                           values: model.memoryHistory.values,
                           maxValue: 100,
                           color: RGBA(230, 120, 40),
                           tip: memTip,
                           systemInfoTab: .memory)
            resizableGraph(index: 2,
                           values: model.ioHistory.values,
                           maxValue: max(1, model.ioHistory.values.max() ?? 1),
                           color: RGBA(70, 140, 240),
                           tip: ioTip,
                           systemInfoTab: .io)

            Spacer(minLength: 8)

            TextField("Filter", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(.bar)
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 20)
    }

    private var targetPickerBanner: some View {
        HStack(spacing: 8) {
            Image("target")
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text("Click another app's window to select its owning process. Press Esc or click in Process Explorer to cancel.")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(height: 1)
        }
    }

    /// A plain colored-icon toolbar button.
    private func iconButton(_ asset: String,
                            tip: String,
                            disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(tip)
    }

    /// A colored-icon toggle button that highlights while active.
    private func iconToggle(_ asset: String,
                            isOn: Bool,
                            tip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .padding(3)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.30) : Color.clear)
                }
        }
        .buttonStyle(.borderless)
        .help(tip)
    }

    /// A small live sparkline whose width is bound to `model.graphWidths[index]`
    /// and can be dragged from a trailing resize handle.
    private func resizableGraph(index: Int,
                                values: [Double],
                                maxValue: Double,
                                color: RGBA,
                                tip: String,
                                systemInfoTab: SystemInfoTab) -> some View {
        @Bindable var model = model
        return ResizableMiniGraph(
            width: $model.graphWidths[index],
            values: values,
            maxValue: maxValue,
            color: color,
            tip: tip,
            action: {
                model.systemInfoTab = systemInfoTab
                openWindow(id: SystemInfoWindow.id)
            }
        )
    }

    private var cpuTip: String {
        String(format: "CPU: %.1f%%", model.snapshot.system.cpuTotalPercent)
    }

    private var memTip: String {
        let s = model.snapshot.system
        guard s.memoryTotal > 0 else { return "Memory" }
        return "Memory: \(ByteFormat.bytes(s.memoryUsed)) / \(ByteFormat.bytes(s.memoryTotal))"
    }

    private var ioTip: String {
        let rate = model.ioHistory.latest ?? 0
        return "I/O (disk + network): \(ByteFormat.bytes(UInt64(max(0, rate))))/s"
    }

    /// Export the current process list to a text/CSV file (Procexp "Save").
    func saveProcessList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.nameFieldStringValue = "processes.csv"
        panel.title = "Save Process List"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = processListCSV()
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }

    /// Build a CSV of the current snapshot (Process, PID, CPU%, Private Bytes,
    /// Working Set, User).
    private func processListCSV() -> String {
        var lines = ["Process,PID,CPU %,Private Bytes,Working Set,User"]
        let records = model.snapshot.processes.values
            .sorted { $0.id.pid < $1.id.pid }
        for r in records {
            func escape(_ s: String) -> String {
                s.contains(",") || s.contains("\"")
                    ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : s
            }
            let row = [
                escape(r.name),
                String(r.id.pid),
                String(format: "%.2f", r.cpuPercent),
                String(r.physFootprint ?? r.residentSize),
                String(r.residentSize),
                escape(r.userName ?? ""),
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    /// Route a context-menu command to the W8 action layer.
    private func handle(_ command: ProcessCommand, _ pid: ProcessID) {
        switch command {
        case .properties:
            openProperties(pid)
        case .kill:
            coordinator.request(.kill, pid: pid, model: model)
        case .killTree:
            coordinator.request(.killTree, pid: pid, model: model)
        case .suspendResume:
            // Toggle based on the process's current suspended state.
            let suspended = model.snapshot.info(pid)?.flags.contains(.suspended) ?? false
            coordinator.request(suspended ? .resume : .suspend, pid: pid, model: model)
        case .setNice(let nice):
            coordinator.setPriority(pid: pid, nice: nice, model: model)
        case .bringToFront:
            coordinator.request(.bringToFront, pid: pid, model: model)
        case .restart:
            coordinator.request(.restart, pid: pid, model: model)
        case .sample:
            model.sampleProcess(pid)
        case .searchOnline:
            model.searchOnline(forProcess: pid)
        case .checkVirusTotal:
            Task { await model.checkVirusTotal(forProcess: pid) }
        case .copy:
            copyToPasteboard(pid)
        }
    }

    /// Copy a short "name (PID)" description of the process to the clipboard.
    private func copyToPasteboard(_ pid: ProcessID) {
        guard let record = model.snapshot.info(pid) else { return }
        let text = "\(record.name) (PID \(record.id.pid))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens (or refocuses) the Process Properties window for a process.
    private func openProperties(_ pid: ProcessID) {
        openWindow(id: PropertiesWindow.id, value: pid)
    }

    // MARK: Status bar

    /// Compact Procexp-style status bar: CPU usage, commit charge (used/total
    /// physical memory), process count, and physical-memory usage %, each in
    /// its own spaced segment and updated live from `model.snapshot.system`.
    private var statusBar: some View {
        let system = model.snapshot.system
        return HStack(spacing: 0) {
            statusSegment("CPU Usage",
                          String(format: "%.1f%%", system.cpuTotalPercent))
            statusSeparator
            statusSegment("Commit Charge", memoryText(system))
            statusSeparator
            statusSegment("Processes", "\(system.processCount)")
            statusSeparator
            statusSegment("Physical Usage", physicalUsageText(system))
            Spacer(minLength: 8)
            statusSegment("Refresh", refreshLabel)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(.bar)
    }

    /// A "Label: value" pair for one status-bar segment.
    private func statusSegment(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .fixedSize()
    }

    private var statusSeparator: some View {
        Divider().frame(height: 12)
    }

    private var refreshLabel: String {
        model.paused
            ? "Paused"
            : (model.refreshInterval < 1
                ? String(format: "%.1fs", model.refreshInterval)
                : "\(Int(model.refreshInterval))s")
    }

    private func memoryText(_ system: SystemStats) -> String {
        guard system.memoryTotal > 0 else { return "—" }
        let used = ByteFormat.bytes(system.memoryUsed)
        let total = ByteFormat.bytes(system.memoryTotal)
        return "\(used) / \(total)"
    }

    /// Physical memory usage as a percentage of installed RAM.
    private func physicalUsageText(_ system: SystemStats) -> String {
        guard system.memoryTotal > 0 else { return "—" }
        let pct = Double(system.memoryUsed) / Double(system.memoryTotal) * 100
        return String(format: "%.0f%%", pct)
    }
}

private struct SpacePauseMonitor: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.attach(to: view)
    }

    final class Coordinator {
        var action: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === self.view?.window,
                      event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !Self.isTextInput(event.window?.firstResponder)
                else { return event }
                self.action()
                return nil
            }
        }

        private static func isTextInput(_ responder: Any?) -> Bool {
            var current = responder as? NSResponder
            while let item = current {
                if item is NSTextView || item is NSTextField { return true }
                current = item.nextResponder
            }
            return false
        }
    }
}

/// A live toolbar mini history graph with a draggable trailing resize handle.
/// The graph width is bound to the shared `AppModel.graphWidths` array so each
/// of the three toolbar graphs can be sized independently, and the value
/// persists for the lifetime of the session.
private struct ResizableMiniGraph: View {
    @Binding var width: Double
    var values: [Double]
    var maxValue: Double
    var color: RGBA
    var tip: String
    var action: () -> Void

    /// Width captured at the start of a drag so the delta is applied cleanly.
    @State private var dragStartWidth: Double?

    private let minWidth: Double = 28
    private let maxWidth: Double = 320
    private let graphHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 2) {
            SparklineRepresentable(
                values: values,
                maxValue: maxValue,
                lineColor: color,
                fillColor: RGBA(r: color.r, g: color.g, b: color.b, a: 0.28),
                backgroundColor: RGBA(12, 12, 12)
            )
            .frame(width: max(minWidth, width), height: graphHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(tip)

            resizeHandle
        }
    }

    /// A thin trailing grabber; dragging it adjusts this graph's width.
    private var resizeHandle: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary.opacity(0.35))
            .frame(width: 3, height: graphHeight - 2)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = start }
                        width = min(maxWidth, max(minWidth, start + value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize this graph")
    }
}

/// R1 — a simple "Run…" launcher (Procexp File ▸ Run…, ⌘R). Launches an
/// executable path or app with `NSWorkspace` / `Process`.
struct RunProcessSheet: View {    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run")
                .font(.headline)
            Text("Type the path of a program, app, document or folder and it will be opened.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("/path/to/program or /Applications/App.app", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("Browse…") { browse() }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func run() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        let isApp = url.pathExtension.lowercased() == "app"
        let isExecutable = FileManager.default.isExecutableFile(atPath: url.path)

        if isApp || !isExecutable {
            // Apps, documents and folders — let the workspace open them.
            NSWorkspace.shared.open(url)
            dismiss()
            return
        }
        // A plain executable — launch it directly.
        let process = Process()
        process.executableURL = url
        do {
            try process.run()
            dismiss()
        } catch {
            errorMessage = "Could not launch: \(error.localizedDescription)"
        }
    }
}
