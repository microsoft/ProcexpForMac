//
//  LowerPaneView.swift
//  R3 — Process-Explorer-style lower pane.
//
//  Shows, for the currently-selected process, its mapped images
//  (DLL-equivalent), open file descriptors (handle-equivalent), or threads,
//  toggled by `AppModel.lowerPaneMode`. Data is re-fetched whenever the
//  selection or mode changes and refreshed on a ~2s cadence while visible.
//
//  R3 additions:
//   • An in-pane header row with a close (✕) button that hides the pane and a
//     DLLs/Handles/Threads segmented toggle that stays in sync with the menus.
//   • Procexp-style column sets (Name/Description/Company/Version/Path/Signer/
//     Base/Size for images; Type/Name/FD for handles) with resolved bundle
//     metadata, monospaced hex/size, sorting and a filter box.
//   • Single-click selects a row; double-click opens a detail window
//     (`ModuleDetailWindow` / `HandleDetailWindow`).
//

import SwiftUI
import AppKit
import ProcexpModel

/// Which list the lower pane shows. Persisted (view-state) on `AppModel`.
enum LowerPaneMode: String, CaseIterable, Identifiable, Sendable {
    case modules      // mapped images / dylibs — Procexp "DLLs"
    case handles      // open file descriptors — Procexp "Handles"
    case threads      // per-process threads

    var id: String { rawValue }

    /// Short segmented-control label.
    var title: String {
        switch self {
        case .modules: return "DLLs"
        case .handles: return "Handles"
        case .threads: return "Threads"
        }
    }

    /// Used in the empty-state sentence.
    var pluralNoun: String {
        switch self {
        case .modules: return "mapped images"
        case .handles: return "open file descriptors"
        case .threads: return "threads"
        }
    }
}

/// A displayable image row: a `ModuleInfo` plus resolved bundle metadata
/// (description / company / version). Precomputed off the main actor so the
/// `Table` stays cheap to render and sort.
struct ModuleRow: Identifiable, Hashable, Sendable {
    let module: ModuleInfo
    let description: String
    let company: String
    let version: String
    let signature: SignatureInfo?

    var id: String { module.path }
    var name: String { module.name }
    var path: String { module.path }
    var signer: String { (signature ?? module.signing)?.signerDescription ?? "" }
    var loadAddress: UInt64 { module.loadAddress }
    var size: UInt64 { module.size }
}

struct LowerPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    // Fetched lists (both kept so a mode switch shows instantly on next tick).
    @State private var moduleRows: [ModuleRow] = []
    @State private var moduleHighlights: [String: TimedListRowHighlight] = [:]
    @State private var moduleSignatureCache: [String: SignatureInfo] = [:]
    // The set of image IDs the provider actually reported last cycle (excludes
    // fading "deleted" ghosts) plus the ghost rows still being shown, so the
    // diff highlighting can retire a deleted row once its highlight expires.
    @State private var liveModuleIDs: Set<String> = []
    @State private var moduleGhosts: [String: ModuleRow] = [:]
    @State private var descriptors: [FileDescriptorInfo] = []
    @State private var descriptorHighlights: [String: TimedListRowHighlight] = [:]
    @State private var liveDescriptorIDs: Set<String> = []
    @State private var descriptorGhosts: [String: FileDescriptorInfo] = [:]
    @State private var threads: [ThreadInfo] = []
    @State private var note: String?
    @State private var isRetrieving = false

    @State private var filterText: String = ""
    @State private var selectedModuleID: ModuleRow.ID?
    @State private var selectedFDID: FileDescriptorInfo.ID?
    @State private var selectedThreadID: ThreadInfo.ID?

    @State private var moduleSort: [KeyPathComparator<ModuleRow>] =
        [KeyPathComparator(\.name, order: .forward)]
    @State private var fdSort: [KeyPathComparator<FileDescriptorInfo>] =
        [KeyPathComparator(\.id, order: .forward)]
    @State private var threadSort: [KeyPathComparator<ThreadInfo>] =
        [KeyPathComparator(\.id, order: .forward)]

    /// Re-runs the fetch loop whenever the selection or mode changes.
    private struct FetchKey: Equatable {
        let pid: ProcessID?
        let mode: LowerPaneMode
    }

    private var fetchKey: FetchKey {
        FetchKey(pid: model.selection, mode: model.lowerPaneMode)
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header(model: model)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: fetchKey) {
            resetForSelectionChange()
            await refreshLoop(for: fetchKey)
        }
    }

    // MARK: Header (close · mode toggle · count · filter)

    private func header(model: AppModel) -> some View {
        HStack(spacing: 10) {
            Button {
                model.showLowerPane = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Close the lower pane (⌘L)")

            Picker("", selection: Bindable(model).lowerPaneMode) {
                ForEach(LowerPaneMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 225)
            .help("Show mapped images (⌘D), open handles / file descriptors (⌘H), or threads (⌘Y)")

            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            TextField("Filter", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var countLabel: String {
        switch model.lowerPaneMode {
        case .modules: return "\(filteredModules.count) images"
        case .handles: return "\(filteredDescriptors.count) handles"
        case .threads: return "\(filteredThreads.count) threads"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.selection == nil {
            message("Select a process to view its \(model.lowerPaneMode.pluralNoun).")
        } else if isRetrieving && currentModeIsEmpty {
            message("Retrieving data…")
        } else {
            switch model.lowerPaneMode {
            case .modules:
                if let note, filteredModules.isEmpty {
                    message(note)
                } else {
                    modulesTable
                }
            case .handles:
                if let note, filteredDescriptors.isEmpty {
                    message(note)
                } else {
                    handlesTable
                }
            case .threads:
                if let note, threads.isEmpty {
                    message(note)
                } else {
                    VStack(spacing: 0) {
                        if let note {
                            noteBanner(note)
                            Divider()
                        }
                        threadsTable
                    }
                }
            }
        }
    }

    private var currentModeIsEmpty: Bool {
        switch model.lowerPaneMode {
        case .modules: return filteredModules.isEmpty
        case .handles: return filteredDescriptors.isEmpty
        case .threads: return filteredThreads.isEmpty
        }
    }

    private var modulesTable: some View {
        ModuleRowsTable(
            rows: filteredModules,
            columns: AppModel.normalizedModuleColumns(model.moduleColumns),
            highlights: moduleHighlights,
            selection: $selectedModuleID,
            onDoubleClick: openModuleDetail,
            onSearchOnline: searchOnline,
            onCheckVirusTotal: checkVirusTotal
        )
    }

    private var handlesTable: some View {
        FileDescriptorRowsTable(
            rows: filteredDescriptors,
            columns: AppModel.normalizedHandleColumns(model.handleColumns),
            highlights: descriptorHighlights,
            selection: $selectedFDID,
            onDoubleClick: openHandleDetail
        )
    }

    private var threadsTable: some View {
        ThreadRowsTable(
            rows: filteredThreads,
            columns: AppModel.normalizedThreadColumns(model.threadColumns),
            selection: $selectedThreadID
        )
    }

    private func noteBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail windows (double-click)

    private func openModuleDetail(_ row: ModuleRow) {
        guard let pid = model.selection else { return }
        let processName = model.snapshot.info(pid)?.name ?? ""
        openWindow(id: ModuleDetailWindow.id, value: ModuleDetailID(
            pid: pid.pid,
            startTime: pid.startTime,
            path: row.path,
            name: row.name,
            loadAddress: row.module.loadAddress,
            size: row.module.size,
            isMappedFile: row.module.isMappedFile,
            processName: processName
        ))
    }

    private func searchOnline(_ row: ModuleRow) {
        model.searchOnlineForImage(name: row.name, path: row.path)
    }

    private func checkVirusTotal(_ row: ModuleRow) {
        Task {
            await model.checkVirusTotalForImage(name: row.name, path: row.path, signature: row.signature ?? row.module.signing)
        }
    }

    private func openHandleDetail(_ fd: FileDescriptorInfo) {
        guard let pid = model.selection else { return }
        let processName = model.snapshot.info(pid)?.name ?? ""
        openWindow(id: HandleDetailWindow.id, value: HandleDetailID(
            pid: pid.pid,
            startTime: pid.startTime,
            fd: fd.id,
            kind: fd.kind.rawValue,
            name: fd.name,
            processName: processName
        ))
    }

    // MARK: Filtering + sorting

    private var filteredModules: [ModuleRow] {
        let base: [ModuleRow]
        if filterText.isEmpty {
            base = moduleRows
        } else {
            base = moduleRows.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
                    || $0.path.localizedCaseInsensitiveContains(filterText)
                    || $0.description.localizedCaseInsensitiveContains(filterText)
                    || $0.company.localizedCaseInsensitiveContains(filterText)
            }
        }
        return base.sorted(using: moduleSort)
    }

    private var filteredDescriptors: [FileDescriptorInfo] {
        let base: [FileDescriptorInfo]
        if filterText.isEmpty {
            base = descriptors
        } else {
            base = descriptors.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
                    || $0.kind.rawValue.localizedCaseInsensitiveContains(filterText)
                    || String($0.id).contains(filterText)
            }
        }
        return base.sorted(using: fdSort)
    }

    private var filteredThreads: [ThreadInfo] {
        let base: [ThreadInfo]
        if filterText.isEmpty {
            base = threads
        } else {
            base = threads.filter {
                String($0.id).contains(filterText)
                    || $0.state.localizedCaseInsensitiveContains(filterText)
                    || String($0.basePriority).contains(filterText)
            }
        }
        return base.sorted(using: threadSort)
    }

    // MARK: Fetching

    /// Fetches immediately then re-fetches every ~2s until the task is
    /// cancelled (selection/mode change or the pane goes off-screen).
    private func resetForSelectionChange() {
        moduleRows = []
        descriptors = []
        threads = []
        moduleHighlights = [:]
        descriptorHighlights = [:]
        liveModuleIDs = []
        moduleGhosts = [:]
        liveDescriptorIDs = []
        descriptorGhosts = [:]
        selectedModuleID = nil
        selectedFDID = nil
        selectedThreadID = nil
        note = nil
        isRetrieving = model.selection != nil
    }

    private func refreshLoop(for key: FetchKey) async {
        guard let pid = key.pid else { return }
        while !Task.isCancelled {
            await fetchOnce(pid: pid, mode: key.mode)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func fetchOnce(pid: ProcessID, mode: LowerPaneMode) async {
        if currentModeIsEmpty { isRetrieving = true }
        defer { isRetrieving = false }
        switch mode {
        case .modules:
            do {
                let result = try await model.data.modules(of: pid)
                guard !Task.isCancelled else { return }
                let rows = await Self.buildRows(
                    result,
                    signing: model.signing,
                    cachedSignatures: moduleSignatureCache
                )
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                for row in rows where row.signature != nil {
                    moduleSignatureCache[row.path] = row.signature
                }
                moduleRows = mergeModuleRows(rows)
                note = rows.isEmpty
                    ? emptyModulesNote(record: model.snapshot.info(pid))
                    : nil
            } catch {
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                moduleRows = []
                note = "Mapped images unavailable: \(describe(error))"
            }
        case .handles:
            do {
                let result = try await model.data.fileDescriptors(of: pid)
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                descriptors = mergeDescriptors(result)
                note = result.isEmpty
                    ? emptyHandlesNote(record: model.snapshot.info(pid))
                    : nil
            } catch {
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                descriptors = []
                note = "File descriptors unavailable: \(describe(error))"
            }
        case .threads:
            do {
                let result = try await model.data.threads(of: pid)
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                threads = result
                note = threadDetailNote(for: result)
            } catch {
                guard !Task.isCancelled, model.selection == pid, model.lowerPaneMode == mode else { return }
                threads = []
                note = "Threads unavailable: \(describe(error))"
            }
        }
    }

    private func mergeModuleRows(_ incoming: [ModuleRow]) -> [ModuleRow] {
        let now = Date()
        let expiry = now.addingTimeInterval(max(0.2, model.differenceHighlightDuration))
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incomingByID.keys)

        // Drop expired highlights and any ghost rows whose highlight is gone.
        moduleHighlights = moduleHighlights.filter { $0.value.expiresAt > now }
        moduleGhosts = moduleGhosts.filter { moduleHighlights[$0.key]?.kind == .deleted }

        // First population for this selection: no diff highlighting.
        if liveModuleIDs.isEmpty && moduleGhosts.isEmpty && moduleHighlights.isEmpty {
            liveModuleIDs = incomingIDs
            return incoming
        }

        // Newly appeared images (weren't live last cycle) → green highlight.
        for id in incomingIDs.subtracting(liveModuleIDs) {
            moduleHighlights[id] = TimedListRowHighlight(kind: .new, expiresAt: expiry)
        }
        // A reappearing image is live again; clear any ghost/deleted state.
        for id in incomingIDs where moduleGhosts[id] != nil {
            moduleGhosts[id] = nil
        }
        // Newly removed images (were live, now gone) → red highlight + ghost row.
        for id in liveModuleIDs.subtracting(incomingIDs) {
            if let row = moduleRows.first(where: { $0.id == id }) {
                moduleGhosts[id] = row
            }
            moduleHighlights[id] = TimedListRowHighlight(kind: .deleted, expiresAt: expiry)
        }

        liveModuleIDs = incomingIDs

        // Keep only ghosts whose deleted highlight is still active.
        let ghostRows = moduleGhosts.compactMap { id, row -> ModuleRow? in
            guard let highlight = moduleHighlights[id],
                  highlight.kind == .deleted,
                  highlight.expiresAt > now else { return nil }
            return row
        }
        return incoming + ghostRows
    }

    private func mergeDescriptors(_ incoming: [FileDescriptorInfo]) -> [FileDescriptorInfo] {
        let now = Date()
        let expiry = now.addingTimeInterval(max(0.2, model.differenceHighlightDuration))
        let incomingByKey = Dictionary(incoming.map { (descriptorKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incomingByKey.keys)

        // Drop expired highlights and any ghost rows whose highlight is gone.
        descriptorHighlights = descriptorHighlights.filter { $0.value.expiresAt > now }
        descriptorGhosts = descriptorGhosts.filter { descriptorHighlights[$0.key]?.kind == .deleted }

        // First population for this selection: no diff highlighting.
        if liveDescriptorIDs.isEmpty && descriptorGhosts.isEmpty && descriptorHighlights.isEmpty {
            liveDescriptorIDs = incomingIDs
            return incoming
        }

        // Newly opened descriptors → green highlight.
        for id in incomingIDs.subtracting(liveDescriptorIDs) {
            descriptorHighlights[id] = TimedListRowHighlight(kind: .new, expiresAt: expiry)
        }
        // A reappearing descriptor is live again; clear any ghost/deleted state.
        for id in incomingIDs where descriptorGhosts[id] != nil {
            descriptorGhosts[id] = nil
        }
        // Newly closed descriptors → red highlight + ghost row.
        for id in liveDescriptorIDs.subtracting(incomingIDs) {
            if let fd = descriptors.first(where: { descriptorKey($0) == id }) {
                descriptorGhosts[id] = fd
            }
            descriptorHighlights[id] = TimedListRowHighlight(kind: .deleted, expiresAt: expiry)
        }

        liveDescriptorIDs = incomingIDs

        // Keep only ghosts whose deleted highlight is still active.
        let ghostRows = descriptorGhosts.compactMap { id, fd -> FileDescriptorInfo? in
            guard let highlight = descriptorHighlights[id],
                  highlight.kind == .deleted,
                  highlight.expiresAt > now else { return nil }
            return fd
        }
        return incoming + ghostRows
    }

    private func descriptorKey(_ fd: FileDescriptorInfo) -> String {
        "\(fd.id)|\(fd.kind.rawValue)|\(fd.name)"
    }

    /// Builds displayable image rows, resolving bundle metadata off the main
    /// actor so a large module list never hitches the UI.
    private nonisolated static func buildRows(
        _ modules: [ModuleInfo],
        signing: any SigningProviding,
        cachedSignatures: [String: SignatureInfo]
    ) async -> [ModuleRow] {
        await Task.detached(priority: .utility) { () async -> [ModuleRow] in
            var rows: [ModuleRow] = []
            rows.reserveCapacity(modules.count)
            for module in modules {
                let meta = ModuleMetadata.resolve(path: module.path)
                let signature: SignatureInfo?
                if let existing = module.signing {
                    signature = existing
                } else if let cached = cachedSignatures[module.path] {
                    signature = cached
                } else {
                    signature = await signing.signature(forPath: module.path)
                }
                rows.append(ModuleRow(
                    module: module,
                    description: meta.description,
                    company: meta.company,
                    version: meta.version,
                    signature: signature
                ))
            }
            return rows
        }.value
    }

    // MARK: Helpers

    private func hex(_ value: UInt64) -> String {
        value == 0 ? "" : "0x" + String(value, radix: 16, uppercase: false)
    }

    private func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }

    private func emptyModulesNote(record: ProcessRecord?) -> String {
        let base = "No mapped images were returned."
        if !model.data.capabilities.contains(.modules) {
            return "\(base) Mapped-image enumeration is not available from the current provider."
        }
        if let visibility = visibilityExplanation(for: "mapped image details", record: record) {
            return "\(base) \(visibility)"
        }
        return "\(base) The process may have exited, or macOS returned no image mappings."
    }

    private func emptyHandlesNote(record: ProcessRecord?) -> String {
        let base = "No open file descriptors were returned."
        if let visibility = visibilityExplanation(for: "handle details", record: record) {
            return "\(base) \(visibility)"
        }
        return "\(base) The process may have exited, or it currently has no enumerable descriptors."
    }

    private func visibilityExplanation(for resource: String, record: ProcessRecord?) -> String? {
        let providerHasCrossUserVisibility = model.data.capabilities.contains(.crossUser)
        guard let record else {
            return providerHasCrossUserVisibility
                ? "The process may have exited before details could be enumerated."
                : "macOS may hide \(resource) from the unprivileged sampler; the privileged helper can provide broader visibility."
        }

        let otherUser = !record.flags.contains(.ownProcess)
        let protected = record.uid == 0
            || record.flags.contains(.platformBinary)
            || record.flags.contains(.service)

        if !providerHasCrossUserVisibility && (otherUser || protected) {
            return "macOS may hide \(resource) for processes owned by another user or protected by the system without the privileged helper."
        }
        if providerHasCrossUserVisibility && protected {
            return "macOS may still hide \(resource) for platform-protected system processes."
        }
        return nil
    }

    private func threadDetailNote(for threads: [ThreadInfo]) -> String? {
        guard !threads.isEmpty else {
            return "No threads were returned for this process."
        }
        let stubCount = threads.filter(Self.hasStubThreadDetail).count
        if stubCount == threads.count {
            return "Only thread identifiers are available. macOS may require the privileged helper for richer per-thread data."
        }
        if stubCount > 0 {
            return "Some thread details are unavailable for this process; macOS may require the privileged helper for richer per-thread data."
        }
        return nil
    }

    private nonisolated static func hasStubThreadDetail(_ thread: ThreadInfo) -> Bool {
        let normalizedState = thread.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let missingState = normalizedState.isEmpty || normalizedState == "unknown"
        let missingStart = (thread.startAddress ?? 0) == 0 && (thread.startSymbol?.isEmpty ?? true)
        return thread.cpuPercent == 0
            && thread.cpuTime == 0
            && missingState
            && missingStart
            && thread.currentPriority == 0
            && thread.basePriority == 0
    }

    private nonisolated static func hexString(_ value: UInt64?) -> String {
        guard let value, value != 0 else { return "" }
        return "0x" + String(value, radix: 16, uppercase: false)
    }
}

private struct ModuleRowsTable: NSViewRepresentable {
    let rows: [ModuleRow]
    let columns: [ModuleColumn]
    let highlights: [String: TimedListRowHighlight]
    @Binding var selection: ModuleRow.ID?
    var onDoubleClick: (ModuleRow) -> Void
    var onSearchOnline: (ModuleRow) -> Void
    var onCheckVirusTotal: (ModuleRow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            onDoubleClick: onDoubleClick,
            onSearchOnline: onSearchOnline,
            onCheckVirusTotal: onCheckVirusTotal
        )
    }

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
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.target = context.coordinator
        context.coordinator.installMenu(on: tableView)
        tableView.typeSelectHandler = { text in
            context.coordinator.handleTypeSelect(text)
        }
        for column in columns {
            tableView.addTableColumn(context.coordinator.columnDef(for: column).tableColumn)
        }
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.columns = columns
        context.coordinator.highlights = highlights
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onSearchOnline = onSearchOnline
        context.coordinator.onCheckVirusTotal = onCheckVirusTotal
        guard let tableView = context.coordinator.tableView else { return }
        context.coordinator.syncColumns()
        tableView.reloadData()
        if let selection, let row = rows.firstIndex(where: { $0.id == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @MainActor static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveColumnLayout()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        struct ColumnDef {
            let id: String
            let title: String
            let width: CGFloat
            let alignment: NSTextAlignment

            var tableColumn: NSTableColumn {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.headerCell.alignment = alignment
                column.width = width
                column.minWidth = min(width, 70)
                column.resizingMask = [.userResizingMask]
                return column
            }
        }

        static let persistenceKey = "lowerPane.modules.columns"

        var rows: [ModuleRow] = []
        var columns: [ModuleColumn] = ModuleColumn.defaultColumns
        var highlights: [String: TimedListRowHighlight] = [:]
        var selection: Binding<ModuleRow.ID?>
        var onDoubleClick: (ModuleRow) -> Void
        var onSearchOnline: (ModuleRow) -> Void
        var onCheckVirusTotal: (ModuleRow) -> Void
        weak var tableView: NSTableView?
        private let typeSelectBuffer = TypeSelectBuffer()
        private let rowMenu = NSMenu(title: "Image")

        func columnDef(for column: ModuleColumn) -> ColumnDef {
            ColumnDef(
                id: column.rawValue,
                title: column.title,
                width: CGFloat(column.defaultWidth),
                alignment: column.isRightAligned ? .right : .left
            )
        }

        @MainActor func syncColumns() {
            guard let tableView else { return }
            syncTableColumns(on: tableView, desiredIDs: columns.map(\.rawValue)) { raw in
                guard let column = ModuleColumn(rawValue: raw) else { return nil }
                return columnDef(for: column).tableColumn
            }
        }

        init(selection: Binding<ModuleRow.ID?>,
             onDoubleClick: @escaping (ModuleRow) -> Void,
             onSearchOnline: @escaping (ModuleRow) -> Void,
             onCheckVirusTotal: @escaping (ModuleRow) -> Void) {
            self.selection = selection
            self.onDoubleClick = onDoubleClick
            self.onSearchOnline = onSearchOnline
            self.onCheckVirusTotal = onCheckVirusTotal
        }

        func installMenu(on tableView: NSTableView) {
            rowMenu.autoenablesItems = false
            rowMenu.delegate = self
            func add(_ title: String, _ selector: Selector) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                rowMenu.addItem(item)
            }
            add("Search Online", #selector(menuSearchOnline(_:)))
            add("Check VirusTotal", #selector(menuCheckVirusTotal(_:)))
            rowMenu.addItem(.separator())
            add("Reveal in Finder", #selector(menuRevealInFinder(_:)))
            add("Properties...", #selector(menuProperties(_:)))
            tableView.menu = rowMenu
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("highlightRow"), owner: self) as? HighlightTableRowView
                ?? HighlightTableRowView()
            rowView.identifier = NSUserInterfaceItemIdentifier("highlightRow")
            rowView.highlight = rows.indices.contains(row) ? highlights[rows[row].id]?.kind : nil
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            configure(cell: cell, text: text(for: id, row: rows[row]), alignment: alignment(for: id))
            return cell
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 80 }
            let id = tableView.tableColumns[column].identifier.rawValue
            let alignment = alignment(for: id)
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: alignment == .right
                    ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            ]
            var width = ceil((tableView.tableColumns[column].title as NSString).size(withAttributes: headerAttributes).width) + 24
            for row in rows {
                width = max(width, ceil((text(for: id, row: row) as NSString).size(withAttributes: valueAttributes).width) + 12)
            }
            return width
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            selection.wrappedValue = rows.indices.contains(row) ? rows[row].id : nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu === rowMenu else { return }
            let row = contextRow()
            rowMenu.items.forEach { $0.isEnabled = row != nil }
            if let row {
                let exists = FileManager.default.fileExists(atPath: row.path)
                rowMenu.item(withTitle: "Reveal in Finder")?.isEnabled = exists
            }
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        @MainActor func saveColumnLayout() {
            guard let tableView else { return }
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
                if rows[index].name.lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    selection.wrappedValue = rows[index].id
                    return true
                }
            }
            return false
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            onDoubleClick(rows[row])
        }

        @objc private func menuSearchOnline(_ sender: Any?) {
            guard let row = contextRow() else { return }
            onSearchOnline(row)
        }

        @objc private func menuCheckVirusTotal(_ sender: Any?) {
            guard let row = contextRow() else { return }
            onCheckVirusTotal(row)
        }

        @objc private func menuRevealInFinder(_ sender: Any?) {
            guard let row = contextRow() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
        }

        @objc private func menuProperties(_ sender: Any?) {
            guard let row = contextRow() else { return }
            onDoubleClick(row)
        }

        private func contextRow() -> ModuleRow? {
            guard let tableView else { return nil }
            let rowIndex = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard rows.indices.contains(rowIndex) else { return nil }
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            selection.wrappedValue = rows[rowIndex].id
            return rows[rowIndex]
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = id
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.usesSingleLineMode = true
            textField.cell?.wraps = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func configure(cell: NSTableCellView, text: String, alignment: NSTextAlignment) {
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.font = alignment == .right
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField?.textColor = .labelColor
        }

        private func text(for id: String, row: ModuleRow) -> String {
            switch id {
            case "name": return row.name
            case "description": return row.description
            case "company": return row.company
            case "version": return row.version
            case "path": return row.path
            case "signer": return row.signer
            case "base": return row.loadAddress == 0 ? "" : "0x" + String(row.loadAddress, radix: 16, uppercase: false)
            case "size": return ByteFormat.bytes(row.size)
            default: return ""
            }
        }

        private func alignment(for id: String) -> NSTextAlignment {
            ModuleColumn(rawValue: id)?.isRightAligned == true ? .right : .left
        }

    }
}

private struct FileDescriptorRowsTable: NSViewRepresentable {
    let rows: [FileDescriptorInfo]
    let columns: [HandleColumn]
    let highlights: [String: TimedListRowHighlight]
    @Binding var selection: FileDescriptorInfo.ID?
    var onDoubleClick: (FileDescriptorInfo) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onDoubleClick: onDoubleClick)
    }

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
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.target = context.coordinator
        tableView.typeSelectHandler = { text in
            context.coordinator.handleTypeSelect(text)
        }
        for column in columns {
            tableView.addTableColumn(context.coordinator.columnDef(for: column).tableColumn)
        }
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.columns = columns
        context.coordinator.highlights = highlights
        context.coordinator.onDoubleClick = onDoubleClick
        guard let tableView = context.coordinator.tableView else { return }
        context.coordinator.syncColumns()
        tableView.reloadData()
        if let selection, let row = rows.firstIndex(where: { $0.id == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @MainActor static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveColumnLayout()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnDef {
            let id: String
            let title: String
            let width: CGFloat
            let alignment: NSTextAlignment

            var tableColumn: NSTableColumn {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.headerCell.alignment = alignment
                column.width = width
                column.minWidth = min(width, 44)
                column.resizingMask = [.userResizingMask]
                return column
            }
        }

        static let persistenceKey = "lowerPane.handles.columns.v2"

        var rows: [FileDescriptorInfo] = []
        var columns: [HandleColumn] = HandleColumn.defaultColumns
        var highlights: [String: TimedListRowHighlight] = [:]
        var selection: Binding<FileDescriptorInfo.ID?>
        var onDoubleClick: (FileDescriptorInfo) -> Void
        weak var tableView: NSTableView?
        private let typeSelectBuffer = TypeSelectBuffer()

        func columnDef(for column: HandleColumn) -> ColumnDef {
            ColumnDef(
                id: column.rawValue,
                title: column.title,
                width: CGFloat(column.defaultWidth),
                alignment: column.isRightAligned ? .right : .left
            )
        }

        @MainActor func syncColumns() {
            guard let tableView else { return }
            syncTableColumns(on: tableView, desiredIDs: columns.map(\.rawValue)) { raw in
                guard let column = HandleColumn(rawValue: raw) else { return nil }
                return columnDef(for: column).tableColumn
            }
        }

        init(selection: Binding<FileDescriptorInfo.ID?>, onDoubleClick: @escaping (FileDescriptorInfo) -> Void) {
            self.selection = selection
            self.onDoubleClick = onDoubleClick
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("highlightRow"), owner: self) as? HighlightTableRowView
                ?? HighlightTableRowView()
            rowView.identifier = NSUserInterfaceItemIdentifier("highlightRow")
            rowView.highlight = rows.indices.contains(row) ? highlights[descriptorKey(rows[row])]?.kind : nil
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            configure(cell: cell, text: text(for: id, row: rows[row]), alignment: alignment(for: id))
            return cell
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 80 }
            let id = tableView.tableColumns[column].identifier.rawValue
            let alignment = alignment(for: id)
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: alignment == .right
                    ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            ]
            var width = ceil((tableView.tableColumns[column].title as NSString).size(withAttributes: headerAttributes).width) + 24
            for row in rows {
                width = max(width, ceil((text(for: id, row: row) as NSString).size(withAttributes: valueAttributes).width) + 12)
            }
            return width
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            selection.wrappedValue = rows.indices.contains(row) ? rows[row].id : nil
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        @MainActor func saveColumnLayout() {
            guard let tableView else { return }
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
                if rows[index].name.lowercased().hasPrefix(prefix) || rows[index].kind.rawValue.lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    selection.wrappedValue = rows[index].id
                    return true
                }
            }
            return false
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            onDoubleClick(rows[row])
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = id
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            textField.usesSingleLineMode = true
            textField.cell?.wraps = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func configure(cell: NSTableCellView, text: String, alignment: NSTextAlignment) {
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.font = alignment == .right
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField?.textColor = .labelColor
        }

        private func text(for id: String, row: FileDescriptorInfo) -> String {
            switch id {
            case "kind": return row.kind.rawValue
            case "name": return row.name
            case "access": return FileDescriptorFlagFormatter.access(row.openFlags)
            case "offset": return row.offset.map(String.init) ?? ""
            case "size": return row.vnode.map { ByteFormat.bytes(UInt64(max(0, $0.size))) } ?? ""
            case "status": return FileDescriptorFlagFormatter.status(row.statusFlags)
            case "guardFlags": return FileDescriptorFlagFormatter.guardFlags(row.guardFlags)
            case "vnodeType": return row.vnode?.type.rawValue ?? ""
            case "inode": return row.vnode.map { String($0.inode) } ?? ""
            case "socketFamily": return row.socket?.addressFamily.map(String.init) ?? ""
            case "socketProtocol": return row.socket?.protocolNumber.map(String.init) ?? ""
            case "socketState": return row.socket?.state ?? ""
            case "socketQueues": return queueText(row.socket)
            case "receiveBuffer": return row.socket?.receiveBuffer.map { ByteFormat.bytes(UInt64($0.currentBytes)) } ?? ""
            case "sendBuffer": return row.socket?.sendBuffer.map { ByteFormat.bytes(UInt64($0.currentBytes)) } ?? ""
            case "fd": return String(row.id)
            default: return ""
            }
        }

        private func alignment(for id: String) -> NSTextAlignment {
            HandleColumn(rawValue: id)?.isRightAligned == true ? .right : .left
        }

        private func queueText(_ socket: SocketInfo?) -> String {
            guard let socket, let qlen = socket.queueLength, let qlimit = socket.queueLimit else { return "" }
            return "\(qlen)/\(qlimit)"
        }

        private func descriptorKey(_ fd: FileDescriptorInfo) -> String {
            "\(fd.id)|\(fd.kind.rawValue)|\(fd.name)"
        }
    }
}

private struct ThreadRowsTable: NSViewRepresentable {
    let rows: [ThreadInfo]
    let columns: [ThreadColumn]
    @Binding var selection: ThreadInfo.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

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
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.typeSelectHandler = { text in
            context.coordinator.handleTypeSelect(text)
        }
        for column in columns {
            tableView.addTableColumn(context.coordinator.columnDef(for: column).tableColumn)
        }
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.columns = columns
        guard let tableView = context.coordinator.tableView else { return }
        context.coordinator.syncColumns()
        tableView.reloadData()
        if let selection, let row = rows.firstIndex(where: { $0.id == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @MainActor static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveColumnLayout()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct ColumnDef {
            let id: String
            let title: String
            let width: CGFloat
            let alignment: NSTextAlignment

            var tableColumn: NSTableColumn {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title
                column.headerCell.alignment = alignment
                column.width = width
                column.minWidth = min(width, 52)
                column.resizingMask = [.userResizingMask]
                return column
            }
        }

        static let persistenceKey = "lowerPane.threads.columns.v2"

        var rows: [ThreadInfo] = []
        var columns: [ThreadColumn] = ThreadColumn.defaultColumns
        var selection: Binding<ThreadInfo.ID?>
        weak var tableView: NSTableView?
        private let typeSelectBuffer = TypeSelectBuffer()

        func columnDef(for column: ThreadColumn) -> ColumnDef {
            ColumnDef(
                id: column.rawValue,
                title: column.title,
                width: CGFloat(column.defaultWidth),
                alignment: column.isRightAligned ? .right : .left
            )
        }

        @MainActor func syncColumns() {
            guard let tableView else { return }
            syncTableColumns(on: tableView, desiredIDs: columns.map(\.rawValue)) { raw in
                guard let column = ThreadColumn(rawValue: raw) else { return nil }
                return columnDef(for: column).tableColumn
            }
        }

        init(selection: Binding<ThreadInfo.ID?>) {
            self.selection = selection
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("highlightRow"), owner: self) as? HighlightTableRowView
                ?? HighlightTableRowView()
            rowView.identifier = NSUserInterfaceItemIdentifier("highlightRow")
            rowView.highlight = nil
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            configure(cell: cell, text: text(for: id, row: rows[row]), alignment: alignment(for: id))
            return cell
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 80 }
            let id = tableView.tableColumns[column].identifier.rawValue
            let alignment = alignment(for: id)
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: alignment == .right
                    ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            ]
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            ]
            var width = ceil((tableView.tableColumns[column].title as NSString).size(withAttributes: headerAttributes).width) + 24
            for row in rows {
                width = max(width, ceil((text(for: id, row: row) as NSString).size(withAttributes: valueAttributes).width) + 12)
            }
            return width
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            selection.wrappedValue = rows.indices.contains(row) ? rows[row].id : nil
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        @MainActor func saveColumnLayout() {
            guard let tableView else { return }
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
                if searchableText(for: rows[index]).lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    selection.wrappedValue = rows[index].id
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
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func configure(cell: NSTableCellView, text: String, alignment: NSTextAlignment) {
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.font = alignment == .right
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField?.textColor = .labelColor
        }

        private func text(for id: String, row: ThreadInfo) -> String {
            switch id {
            case "tid": return String(row.id)
            case "name": return row.name
            case "cpu": return String(format: "%.1f%%", row.cpuPercent)
            case "cpuTime": return formatCPUTime(row.cpuTime)
            case "state": return row.state
            case "currentPriority": return row.currentPriority == 0 ? "" : String(row.currentPriority)
            case "basePriority": return row.basePriority == 0 ? "" : String(row.basePriority)
            case "maxPriority": return row.maxPriority == 0 ? "" : String(row.maxPriority)
            case "policy": return policyText(row.schedulerPolicy)
            case "sleepTime": return row.sleepTimeSeconds > 0 ? "\(row.sleepTimeSeconds)s" : ""
            case "flags": return ThreadFlagFormatter.flags(row.flags)
            case "dispatchQueue": return hexString(row.dispatchQueueAddress)
            case "userTime": return formatCPUTime(row.userTime)
            case "kernelTime": return formatCPUTime(row.kernelTime)
            case "startAddress": return row.startSymbol ?? hexString(row.startAddress)
            default: return ""
            }
        }

        private func policyText(_ policy: Int32) -> String {
            switch policy {
            case Int32(POLICY_TIMESHARE): return "Timeshare"
            case Int32(POLICY_RR): return "Round-robin"
            case Int32(POLICY_FIFO): return "FIFO"
            case 0: return ""
            default: return String(policy)
            }
        }

        private func alignment(for id: String) -> NSTextAlignment {
            ThreadColumn(rawValue: id)?.isRightAligned == true ? .right : .left
        }

        private func searchableText(for row: ThreadInfo) -> String {
            [String(row.id), row.name, row.state, String(row.currentPriority), String(row.basePriority), String(row.schedulerPolicy)]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private func hexString(_ value: UInt64?) -> String {
            guard let value, value != 0 else { return "" }
            return "0x" + String(value, radix: 16, uppercase: false)
        }

        private func formatCPUTime(_ nanoseconds: UInt64) -> String {
            guard nanoseconds > 0 else { return "" }
            let totalMilliseconds = nanoseconds / 1_000_000
            let milliseconds = totalMilliseconds % 1_000
            let totalSeconds = totalMilliseconds / 1_000
            let seconds = totalSeconds % 60
            let totalMinutes = totalSeconds / 60
            let minutes = totalMinutes % 60
            let hours = totalMinutes / 60
            if hours > 0 {
                return String(format: "%llu:%02llu:%02llu.%03llu", hours, minutes, seconds, milliseconds)
            }
            return String(format: "%llu:%02llu.%03llu", minutes, seconds, milliseconds)
        }
    }
}

@MainActor
private func syncTableColumns(
    on tableView: NSTableView,
    desiredIDs: [String],
    makeColumn: (String) -> NSTableColumn?
) {
    let desired = desiredIDs.filter { !$0.isEmpty }
    for column in tableView.tableColumns where !desired.contains(column.identifier.rawValue) {
        tableView.removeTableColumn(column)
    }
    for (index, id) in desired.enumerated() {
        if let current = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) {
            if current != index { tableView.moveColumn(current, toColumn: index) }
        } else if let column = makeColumn(id) {
            tableView.addTableColumn(column)
            let current = tableView.tableColumns.count - 1
            if current != index { tableView.moveColumn(current, toColumn: index) }
        }
    }
}
