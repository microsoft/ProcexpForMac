//
//  PropertiesTabs.swift
//  W6 — Process Properties window tab content.
//
//  Each tab is a small SwiftUI view driven by the live `ProcessRecord`
//  (from the snapshot) and/or the per-window `PropertiesDetail` async store.
//

import SwiftUI
import AppKit
import ProcexpModel
import ProcexpGraphs
import UniformTypeIdentifiers

// MARK: - Shared building blocks

private let propertiesLabelWidth: CGFloat = 116

private struct TruncatedValue: View {
    let text: String
    var mono: Bool = false
    var middle: Bool = false

    var body: some View {
        let display = text.isEmpty ? "—" : text
        Text(display)
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .lineLimit(1)
            .truncationMode(middle ? .middle : .tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(display)
    }
}

/// A right-aligned label + selectable value laid out in a `Grid`.
private struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: propertiesLabelWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            TruncatedValue(text: value, mono: mono)
        }
    }
}

/// A single-line selectable value for long paths/names. The embedded AppKit text
/// view behaves like native macOS overflowing fields: the row stays one line,
/// and the value can be scrolled horizontally to inspect the full string.
struct ScrollingValue: View {
    let text: String
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        HorizontalOverflowTextField(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
            .help(text.isEmpty ? "—" : text)
    }
}

private struct HorizontalOverflowTextField: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed

        let textField = NSTextField(labelWithString: "")
        textField.isSelectable = true
        textField.isEditable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.frame = NSRect(x: 0, y: 1, width: 1, height: 20)
        scrollView.documentView = textField
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textField = scrollView.documentView as? NSTextField else { return }
        let display = text.isEmpty ? "—" : text
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if textField.stringValue != display {
            textField.stringValue = display
            scrollView.contentView.scroll(to: .zero)
        }
        textField.font = font
        textField.textColor = .labelColor
        let textWidth = ceil((display as NSString).size(withAttributes: [.font: font]).width) + 20
        let width = max(scrollView.contentSize.width, textWidth)
        if textField.frame.size != NSSize(width: width, height: 20) {
            textField.setFrameSize(NSSize(width: width, height: 20))
        }
    }
}

/// A `Grid` row whose value is a single-line, horizontally scrollable and
/// selectable field (see `ScrollingValue`).
private struct InfoScrollRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: propertiesLabelWidth, height: 22, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            ScrollingValue(text: value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VisibleScrollbarScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .allowed

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: document.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scrollView.documentView = document
        context.coordinator.hostingView = hosting
        context.coordinator.documentView = document
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        guard let document = context.coordinator.documentView,
              let hosting = context.coordinator.hostingView else { return }
        let width = max(1, scrollView.contentSize.width)
        let fitting = hosting.fittingSize
        document.setFrameSize(NSSize(width: width, height: max(scrollView.contentSize.height, fitting.height)))
        hosting.setFrameSize(NSSize(width: width, height: max(fitting.height, scrollView.contentSize.height)))
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
        weak var documentView: NSView?
    }
}

/// A titled `GroupBox` section wrapper used across tabs.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// Resolves and shows a process/file icon from a path.
private struct ProcessIconView: View {
    let path: String?
    var size: CGFloat = 48

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        if let path, !path.isEmpty {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

// MARK: - Image tab

struct ImageTab: View {
    let pid: ProcessID
    let record: ProcessRecord
    @Bindable var detail: PropertiesDetail
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            Section(title: "Image") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    InfoRow(label: "Version", value: record.version ?? "")
                    if let build = detail.buildTime {
                        InfoRow(label: "Build Time", value: build)
                    }
                    InfoScrollRow(label: "Path", value: record.executablePath ?? "")
                    if let autostart = detail.autostartLocation, !autostart.isEmpty {
                        InfoScrollRow(label: "Autostart", value: autostart)
                    }
                    InfoScrollRow(label: "Command Line",
                                  value: detail.commandLine ?? record.executablePath ?? "")
                    if let cwd = detail.currentDirectory, !cwd.isEmpty {
                        InfoScrollRow(label: "Current Directory", value: cwd)
                    }
                    InfoRow(label: "Parent",
                            value: record.parent.map { parentText($0) } ?? "—")
                    InfoRow(label: "User", value: record.userName ?? String(record.uid))
                    InfoRow(label: "Started", value: ByteFormat.dateTime(record.startTimeDate))
                    if let arch = detail.imageArch {
                        InfoRow(label: "Image Type", value: arch)
                    }
                    InfoRow(label: "Mitigations", value: mitigationsText)
                }
            }

            Spacer(minLength: 0)
            buttonRow
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProcessIconView(path: record.executablePath, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayDescription?.isEmpty == false
                     ? record.displayDescription! : record.name)
                    .font(.title3).bold()
                Text(record.companyName ?? "")
                    .foregroundStyle(.secondary)
                Text(record.version.map { "Version \($0)" } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("Bring to Front") {
                model.actionCoordinator.request(.bringToFront, pid: pid, model: model)
            }
            Button("Kill Process") {
                model.actionCoordinator.request(.kill, pid: pid, model: model)
            }
            Button {
                guard let path = record.executablePath, !path.isEmpty else { return }
                Task { await detail.verifySignature(path: path, signing: model.signing) }
            } label: {
                if detail.isVerifying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Verify")
                }
            }
            .disabled((record.executablePath ?? "").isEmpty || detail.isVerifying)

            Button {
                Task { await detail.checkVirusTotal(signing: model.signing) }
            } label: {
                if detail.isCheckingVirusTotal {
                    ProgressView().controlSize(.small)
                } else {
                    Text("VirusTotal")
                }
            }
            .disabled(!detail.canCheckVirusTotal)

            Button("Explore") { reveal() }
                .disabled((record.executablePath ?? "").isEmpty)
        }
    }

    private func parentText(_ parent: ProcessID) -> String {
        if let p = model.snapshot.processes[parent] {
            return "\(p.name) (\(parent.pid))"
        }
        return String(parent.pid)
    }

    private var mitigationsText: String {
        var items: [String] = []
        if record.flags.contains(.sandboxed) { items.append("Sandboxed") }
        if record.flags.contains(.platformBinary) { items.append("Platform Binary") }
        if detail.signature?.isNotarized == true { items.append("Hardened Runtime") }
        return items.isEmpty ? "None detected" : items.joined(separator: ", ")
    }

    private func reveal() {
        guard let path = record.executablePath, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Signature tab

struct SignatureTab: View {
    let record: ProcessRecord
    @Bindable var detail: PropertiesDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sig = detail.signature {
                Section(title: "Code Signature") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        InfoRow(label: "Status", value: sig.status.rawValue.capitalized)
                        InfoRow(label: "Signer", value: sig.signerDescription)
                        InfoRow(label: "Publisher", value: sig.publisherDescription ?? "")
                        InfoRow(label: "Team ID", value: sig.teamID ?? "")
                        if let reason = sig.validationErrorMessage, !reason.isEmpty {
                            InfoRow(label: "Reason", value: reason)
                        }
                        InfoRow(label: "Notarized", value: sig.isNotarized ? "Yes" : "No")
                        InfoRow(label: "Platform Binary", value: sig.isPlatformBinary ? "Yes" : "No")
                        InfoRow(label: "SHA-256", value: sig.sha256 ?? "", mono: true)
                        if let vt = sig.virusTotal {
                            InfoRow(label: "VirusTotal", value: "\(vt.positives) / \(vt.total) detections")
                        }
                    }
                    authorityChain(sig.authority)
                    if let note = detail.virusTotalNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if detail.isVerifying {
                Text("Verifying signature…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text((record.executablePath ?? "").isEmpty ? "No executable path was reported for this process." : "No signature information is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

@ViewBuilder private func authorityChain(_ authority: [String]) -> some View {
    if !authority.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
            Text("Certificate Chain").font(.subheadline).bold()
            ForEach(Array(authority.enumerated()), id: \.offset) { index, name in
                Text("\(String(repeating: "    ", count: index))- \(name)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(name)
            }
        }
    }
}

// MARK: - Performance tab

struct PerformanceTab: View {
    let record: ProcessRecord
    @Bindable var detail: PropertiesDetail

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                cpuSection
                physicalMemorySection
                handlesThreadsSection
            }
            VStack(alignment: .leading, spacing: 8) {
                virtualMemorySection
                ioSection
            }
        }
    }

    private var cpuSection: some View {
        Section(title: "CPU") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "CPU Usage", value: String(format: "%.2f %%", record.cpuPercent))
                InfoRow(label: "Priority", value: String(record.priority))
                InfoRow(label: "Nice", value: String(record.nice))
                InfoRow(label: "CPU Time", value: ByteFormat.duration(nanos: record.cpuTime))
                InfoRow(label: "Thread User Time", value: record.threadUserTime.map(ByteFormat.duration) ?? "—")
                InfoRow(label: "Thread Kernel Time", value: record.threadSystemTime.map(ByteFormat.duration) ?? "—")
                InfoRow(label: "Running Threads", value: record.runningThreadCount.map(String.init) ?? "—")
                InfoRow(label: "Task Policy", value: record.taskPolicy.map(String.init) ?? "—")
                InfoRow(label: "Context Switches", value: record.contextSwitches.map(String.init) ?? "—")
            }
        }
    }

    private var virtualMemorySection: some View {
        Section(title: "Virtual Memory") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "Private Bytes", value: bytes(record.physFootprint ?? record.residentSize))
                InfoRow(label: "Virtual Size", value: bytes(record.virtualSize))
                InfoRow(label: "Page Faults", value: record.pageFaults.map(String.init) ?? "—")
                InfoRow(label: "Page Fault Delta", value: String(detail.pageFaultDelta))
                InfoRow(label: "Page Ins", value: record.pageIns.map(String.init) ?? "—")
                InfoRow(label: "COW Faults", value: record.copyOnWriteFaults.map(String.init) ?? "—")
            }
        }
    }

    private var physicalMemorySection: some View {
        Section(title: "Physical Memory") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "Working Set", value: bytes(record.residentSize))
            }
        }
    }

    private var ioSection: some View {
        Section(title: "I/O") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "Reads", value: bytesOrDash(record.diskBytesRead))
                InfoRow(label: "Writes", value: bytesOrDash(record.diskBytesWritten))
                InfoRow(label: "Mach Msg Sent", value: record.machMessagesSent.map(String.init) ?? "—")
                InfoRow(label: "Mach Msg Received", value: record.machMessagesReceived.map(String.init) ?? "—")
                InfoRow(label: "Mach Syscalls", value: record.machSyscalls.map(String.init) ?? "—")
                InfoRow(label: "Unix Syscalls", value: record.unixSyscalls.map(String.init) ?? "—")
            }
        }
    }

    private var handlesThreadsSection: some View {
        Section(title: "Handles / Threads") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "File Descriptors", value: record.fileDescriptorCount.map(String.init) ?? "—")
                InfoRow(label: "Threads", value: String(record.threadCount))
            }
        }
    }

    private func bytes(_ v: UInt64) -> String {
        v == 0 ? "0 B" : ByteFormat.bytes(v)
    }
    private func bytesOrDash(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        return v == 0 ? "0 B" : ByteFormat.bytes(v)
    }
}

// MARK: - Performance Graph tab

/// Per-process history graphs stacked vertically (CPU %, Private Bytes,
/// I/O bytes/sec). Fed by the rings in `PropertiesDetail`, which accumulate
/// one sample per snapshot tick while this window is open. Mirrors Procexp's
/// per-process graph tab.
struct PerformanceGraphTab: View {
    @Bindable var detail: PropertiesDetail

    var body: some View {
        VStack(spacing: 12) {
            GraphPanel(
                title: "CPU",
                values: detail.cpuRing.values,
                color: RGBA(0, 200, 0),
                maxValue: max(100, (detail.cpuRing.values.max() ?? 0) * 1.1),
                readout: String(format: "%.2f %%", detail.cpuRing.latest ?? 0)
            )
            GraphPanel(
                title: "Private Bytes",
                values: detail.privateRing.values,
                color: RGBA(210, 90, 210),
                maxValue: max(1, (detail.privateRing.values.max() ?? 1) * 1.15),
                readout: ByteFormat.bytes(UInt64(detail.privateRing.latest ?? 0))
            )
            GraphPanel(
                title: "I/O Bytes",
                values: detail.ioRing.values,
                color: RGBA(230, 160, 40),
                maxValue: max(1, (detail.ioRing.values.max() ?? 1) * 1.15),
                readout: "\(ByteFormat.bytes(UInt64(detail.ioRing.latest ?? 0)))/s"
            )
        }
    }
}

/// One labelled history graph with a current-value readout.
private struct GraphPanel: View {
    let title: String
    let values: [Double]
    let color: RGBA
    let maxValue: Double
    let readout: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text(readout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HistoryGraphRepresentable(
                series: [values],
                seriesColors: [color],
                maxValue: maxValue,
                gridColor: RGBA(40, 40, 40),
                backgroundColor: RGBA(12, 12, 12)
            )
            .frame(minHeight: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Threads tab

struct ThreadsTab: View {
    let record: ProcessRecord
    @Bindable var detail: PropertiesDetail
    @State private var selectedThreads = Set<ThreadInfo.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if detail.threads.isEmpty {
                Text("No per-thread detail available. The unprivileged sampler reports \(record.threadCount) thread(s); full per-thread CPU and stacks require the privileged helper (task port).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                Table(detail.threads, selection: $selectedThreads) {
                    TableColumn("TID") { thread in tooltipText(String(thread.id), selected: selectedThreads.contains(thread.id)).monospacedDigit() }
                    TableColumn("CPU %") { thread in tooltipText(String(format: "%.2f", thread.cpuPercent), selected: selectedThreads.contains(thread.id)).monospacedDigit() }
                    TableColumn("State") { thread in tooltipText(thread.state.isEmpty ? "—" : thread.state, selected: selectedThreads.contains(thread.id)) }
                }
            }
        }
        .padding(8)
    }
}

// MARK: - TCP/IP tab

struct TCPIPTab: View {
    @Bindable var detail: PropertiesDetail

    var body: some View {
        VStack {
            if detail.sockets.isEmpty {
                Text(detail.socketNote ?? "No TCP/IP sockets were returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                SocketRowsTable(sockets: detail.sockets, remoteNames: detail.socketRemoteNames, highlights: detail.socketHighlights)
            }
        }
    }
}

private struct SocketRowsTable: NSViewRepresentable {
    let sockets: [SocketInfo]
    let remoteNames: [String: String]
    let highlights: [String: TimedListRowHighlight]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let tableView = BorderlessGridTableView()
        context.coordinator.tableView = tableView
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = ResizingCursorTableHeaderView()
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.typeSelectHandler = { text in
            context.coordinator.handleTypeSelect(text)
        }
        for column in Coordinator.columns {
            tableView.addTableColumn(column.tableColumn)
        }
        context.coordinator.autosizesColumns = !TableColumnPersistence.hasSavedLayout(key: Coordinator.persistenceKey)
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sockets = sockets
        context.coordinator.remoteNames = remoteNames
        context.coordinator.highlights = highlights
        context.coordinator.tableView?.reloadData()
        context.coordinator.autosizeColumns()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnDef {
            let id: String
            let title: String
            let width: CGFloat

            var tableColumn: NSTableColumn {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.width = width
                column.minWidth = min(width, 70)
                column.resizingMask = [.userResizingMask, .autoresizingMask]
                return column
            }
        }

        static let columns = [
            ColumnDef(id: "proto", title: "Proto", width: 80),
            ColumnDef(id: "local", title: "Local Address", width: 240),
            ColumnDef(id: "remote", title: "Remote Address", width: 240),
            ColumnDef(id: "remoteName", title: "Remote Name", width: 220),
            ColumnDef(id: "state", title: "State", width: 120),
        ]
        static let persistenceKey = "properties.tcpip.columns"

        var sockets: [SocketInfo] = []
        var remoteNames: [String: String] = [:]
        var highlights: [String: TimedListRowHighlight] = [:]
        weak var tableView: NSTableView?
        var autosizesColumns = true
        private var suppressColumnPersistence = false
        private let typeSelectBuffer = TypeSelectBuffer()

        func numberOfRows(in tableView: NSTableView) -> Int { sockets.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("highlightRow"), owner: self) as? HighlightTableRowView
                ?? HighlightTableRowView()
            rowView.identifier = NSUserInterfaceItemIdentifier("highlightRow")
            rowView.highlight = sockets.indices.contains(row) ? highlights[socketKey(sockets[row])]?.kind : nil
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard sockets.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            let value = text(for: id, socket: sockets[row])
            cell.textField?.stringValue = value
            cell.textField?.toolTip = value.isEmpty ? nil : value
            cell.toolTip = value.isEmpty ? nil : value
            return cell
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 80 }
            return autosizeWidth(for: tableView.tableColumns[column])
        }

        func autosizeColumns() {
            guard autosizesColumns, let tableView else { return }
            suppressColumnPersistence = true
            defer { suppressColumnPersistence = false }
            for column in tableView.tableColumns {
                column.width = autosizeWidth(for: column)
            }
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView, !suppressColumnPersistence else { return }
            autosizesColumns = false
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView, !suppressColumnPersistence else { return }
            autosizesColumns = false
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func handleTypeSelect(_ text: String) -> Bool {
            let prefix = typeSelectBuffer.append(text)
            if selectNext(matching: prefix) { return true }
            return selectNext(matching: typeSelectBuffer.reset(to: text))
        }

        private func selectNext(matching prefix: String) -> Bool {
            guard !sockets.isEmpty, let tableView else { return false }
            let start = tableView.selectedRow >= 0 ? tableView.selectedRow : -1
            for offset in 1...sockets.count {
                let index = (start + offset) % sockets.count
                let socket = sockets[index]
                if socket.proto.rawValue.lowercased().hasPrefix(prefix)
                    || endpoint(socket.localAddress, socket.localPort).lowercased().hasPrefix(prefix)
                    || endpoint(socket.remoteAddress, socket.remotePort).lowercased().hasPrefix(prefix)
                    || socket.state.lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    return true
                }
            }
            return false
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = id
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.usesSingleLineMode = true
            textField.cell?.wraps = false
            textField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textField.textColor = .labelColor
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func autosizeWidth(for column: NSTableColumn) -> CGFloat {
            let id = column.identifier.rawValue
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let valueAttributes: [NSAttributedString.Key: Any] = [.font: font]
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            ]
            var width = ceil((column.title as NSString).size(withAttributes: headerAttributes).width) + 28
            for socket in sockets {
                let value = text(for: id, socket: socket)
                width = max(width, ceil((value as NSString).size(withAttributes: valueAttributes).width) + 16)
            }
            return max(column.minWidth, width)
        }

        private func text(for id: String, socket: SocketInfo) -> String {
            switch id {
            case "proto": return socket.proto.rawValue.uppercased()
            case "local": return endpoint(socket.localAddress, socket.localPort)
            case "remote": return endpoint(socket.remoteAddress, socket.remotePort)
            case "remoteName": return remoteNames[socketKey(socket)] ?? ""
            case "state": return socket.state.isEmpty ? "—" : socket.state
            default: return ""
            }
        }

        private func endpoint(_ address: String, _ port: UInt16) -> String {
            let host = address.isEmpty ? "*" : address
            return port == 0 ? host : "\(host):\(port)"
        }

        private func socketKey(_ socket: SocketInfo) -> String {
            "\(socket.id)|\(socket.proto.rawValue)|\(socket.localAddress)|\(socket.localPort)|\(socket.remoteAddress)|\(socket.remotePort)|\(socket.state)"
        }
    }
}

// MARK: - Environment tab

struct EnvironmentTab: View {
    @Bindable var detail: PropertiesDetail
    @State private var selectedVariables = Set<EnvVar.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if detail.environment.isEmpty {
                Text(detail.environmentNote ?? "No environment variables.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                EnvironmentRowsTable(rows: detail.environment, selection: $selectedVariables)
            }
        }
    }
}

private struct EnvironmentRowsTable: NSViewRepresentable {
    let rows: [EnvVar]
    @Binding var selection: Set<EnvVar.ID>

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let tableView = BorderlessGridTableView()
        context.coordinator.tableView = tableView
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = ResizingCursorTableHeaderView()
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = true
        tableView.typeSelectHandler = { text in context.coordinator.handleTypeSelect(text) }
        for column in Coordinator.columns { tableView.addTableColumn(column.tableColumn) }
        context.coordinator.autosizesColumns = !TableColumnPersistence.hasSavedLayout(key: Coordinator.persistenceKey)
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.selection = $selection
        context.coordinator.tableView?.reloadData()
        context.coordinator.autosizeColumns()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnDef {
            let id: String
            let title: String
            let width: CGFloat

            var tableColumn: NSTableColumn {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.width = width
                column.minWidth = min(width, 80)
                column.resizingMask = [.userResizingMask, .autoresizingMask]
                return column
            }
        }

        static let columns = [
            ColumnDef(id: "variable", title: "Variable", width: 180),
            ColumnDef(id: "value", title: "Value", width: 520),
        ]
        static let persistenceKey = "properties.environment.columns"

        var rows: [EnvVar] = []
        var selection: Binding<Set<EnvVar.ID>>
        weak var tableView: NSTableView?
        var autosizesColumns = true
        private var suppressColumnPersistence = false
        private let typeSelectBuffer = TypeSelectBuffer()

        init(selection: Binding<Set<EnvVar.ID>>) {
            self.selection = selection
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            let value = text(for: id, row: rows[row])
            cell.textField?.stringValue = value
            cell.textField?.toolTip = value.isEmpty ? nil : value
            cell.toolTip = value.isEmpty ? nil : value
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            var selected = Set<EnvVar.ID>()
            for index in tableView.selectedRowIndexes where rows.indices.contains(index) {
                selected.insert(rows[index].id)
            }
            selection.wrappedValue = selected
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 80 }
            return autosizeWidth(for: tableView.tableColumns[column])
        }

        func autosizeColumns() {
            guard autosizesColumns, let tableView else { return }
            suppressColumnPersistence = true
            defer { suppressColumnPersistence = false }
            for column in tableView.tableColumns {
                column.width = autosizeWidth(for: column)
            }
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView, !suppressColumnPersistence else { return }
            autosizesColumns = false
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView, !suppressColumnPersistence else { return }
            autosizesColumns = false
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func handleTypeSelect(_ text: String) -> Bool {
            let prefix = typeSelectBuffer.append(text)
            if selectNext(matching: prefix) { return true }
            return selectNext(matching: typeSelectBuffer.reset(to: text))
        }

        private func selectNext(matching prefix: String) -> Bool {
            guard !rows.isEmpty, let tableView else { return false }
            let start = tableView.selectedRow >= 0 ? tableView.selectedRow : -1
            for offset in 1...rows.count {
                let index = (start + offset) % rows.count
                if rows[index].id.lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    selection.wrappedValue = [rows[index].id]
                    return true
                }
            }
            return false
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = id
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.usesSingleLineMode = true
            textField.cell?.wraps = false
            textField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textField.textColor = .labelColor
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func autosizeWidth(for column: NSTableColumn) -> CGFloat {
            let id = column.identifier.rawValue
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let valueAttributes: [NSAttributedString.Key: Any] = [.font: font]
            let headerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]
            var width = ceil((column.title as NSString).size(withAttributes: headerAttributes).width) + 28
            for row in rows {
                width = max(width, ceil((text(for: id, row: row) as NSString).size(withAttributes: valueAttributes).width) + 18)
            }
            return max(column.minWidth, min(width, id == "variable" ? 360 : 1200))
        }

        private func text(for id: String, row: EnvVar) -> String {
            switch id {
            case "variable": return row.id
            case "value": return row.value
            default: return ""
            }
        }
    }
}

// MARK: - Strings tab

struct StringsTab: View {
    @Bindable var detail: PropertiesDetail
    @State private var filter = ""
    @State private var selectedRows = Set<Int>()

    private var filtered: [String] {
        guard !filter.isEmpty else { return detail.strings }
        return detail.strings.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Text("\(filtered.count) of \(detail.strings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save…") { save() }
                    .disabled(filtered.isEmpty)
            }

            if detail.strings.isEmpty {
                Text(detail.stringsNote ?? "No strings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Image strings (memory strings require the privileged helper).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VisibleScrollbarScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { offset, line in
                            tooltipText(line, selected: selectedRows.contains(offset))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .tag(offset)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "strings.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = filtered.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func selectableText(_ text: String, selected: Bool) -> Text {
    Text(text).foregroundStyle(selected ? Color.white : Color.primary)
}

private func tooltipText(_ text: String, selected: Bool) -> some View {
    let display = text.isEmpty ? "—" : text
    return Text(display)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .help(display)
}

// MARK: - Security tab

struct SecurityTab: View {
    let record: ProcessRecord
    @Bindable var detail: PropertiesDetail

    var body: some View {
        VisibleScrollbarScrollView {
            VStack(alignment: .leading, spacing: 10) {
                identitySection
                entitlementsSection
                sandboxRuntimeSection
            }
        }
    }

    @ViewBuilder private var identitySection: some View {
        Section(title: "Identity") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "User", value: principal(record.uid, record.userName))
                InfoRow(label: "Effective UID",
                        value: principal(identity?.effectiveUID ?? record.uid,
                                         identity?.effectiveUserName ?? record.userName))
                InfoRow(label: "Real UID",
                        value: principal(identity?.realUID, identity?.realUserName))
                InfoRow(label: "Saved UID",
                        value: principal(identity?.savedUID, identity?.savedUserName))
                InfoRow(label: "Effective GID",
                        value: group(identity?.effectiveGID, identity?.effectiveGroupName))
                InfoRow(label: "Real GID",
                        value: group(identity?.realGID, identity?.realGroupName))
                InfoRow(label: "Saved GID",
                        value: group(identity?.savedGID, identity?.savedGroupName))
                InfoRow(label: "Account Group",
                        value: group(identity?.accountPrimaryGID, identity?.accountPrimaryGroupName))
                InfoRow(label: "Session (TTY)", value: record.sessionTTY ?? "—")
                InfoRow(label: "launchd Managed",
                        value: record.flags.contains(.service) ? "Yes" : "No")
            }
        }
    }

    @ViewBuilder private var entitlementsSection: some View {
        Section(title: "Entitlements") {
            if let code = detail.securityCode {
                if code.entitlements.isEmpty {
                    Text(code.entitlementsNote ?? "No entitlements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(code.entitlements) { entitlement in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entitlement.key)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 260, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entitlement.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(entitlement.value)
                            }
                        }
                    }
                }
            } else {
                Text("Loading entitlements…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sandboxRuntimeSection: some View {
        Section(title: "Sandbox / Runtime") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                InfoRow(label: "App Sandbox", value: sandboxStatus)
                InfoRow(label: "Sandbox Source", value: sandboxSource)
                InfoRow(label: "Hardened Runtime", value: hardenedRuntimeStatus)
                InfoRow(label: "Runtime Source", value: detail.securityCode?.hardenedRuntimeNote ?? "Loading…")
                InfoRow(label: "Platform Binary",
                        value: record.flags.contains(.platformBinary) ? "Yes" : "No")
            }
        }
    }

    private var identity: ProcessSecurityIdentity? { detail.securityIdentity }

    private func principal(_ uid: UInt32?, _ name: String?) -> String {
        guard let uid else { return "—" }
        if let name, !name.isEmpty { return "\(name) (\(uid))" }
        return String(uid)
    }

    private func group(_ gid: UInt32?, _ name: String?) -> String {
        guard let gid else { return "—" }
        if let name, !name.isEmpty { return "\(name) (\(gid))" }
        return String(gid)
    }

    private var sandboxStatus: String {
        if detail.securityCode?.appSandboxEntitlement == true { return "Yes" }
        if record.flags.contains(.sandboxed) { return "Yes" }
        if detail.securityCode?.appSandboxEntitlement == false { return "No" }
        return "No sandbox signal detected"
    }

    private var sandboxSource: String {
        if detail.securityCode?.appSandboxEntitlement == true {
            return "com.apple.security.app-sandbox entitlement"
        }
        if record.flags.contains(.sandboxed) {
            return "Process flag from sampler"
        }
        if detail.securityCode?.appSandboxEntitlement == false {
            return "App Sandbox entitlement is false"
        }
        return "No App Sandbox entitlement or sampler flag"
    }

    private var hardenedRuntimeStatus: String {
        guard let hardened = detail.securityCode?.hardenedRuntime else { return "Unavailable" }
        return hardened ? "Yes" : "No"
    }
}
