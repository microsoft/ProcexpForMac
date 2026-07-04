//
//  FindHandleDLLView.swift
//  Process Explorer-style search for mapped images and handles.
//

import SwiftUI
import AppKit
import ProcexpModel

struct FindHandleDLLView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [FindHandleDLLResult] = []
    @State private var isSearching = false
    @State private var searchedCount = 0
    @State private var totalCount = 0
    @State private var selectedID: FindHandleDLLResult.ID?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultTable
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 420, idealHeight: 520)
        .onDisappear { searchTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Substring")
                .foregroundStyle(.secondary)
            TextField("DLL, mapped image, handle path, or name", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startSearch() }
            Button(isSearching ? "Stop" : "Search") {
                isSearching ? stopSearch() : startSearch()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching)
        }
        .padding(12)
    }

    private var resultTable: some View {
        FindResultsTable(
            results: results,
            selection: $selectedID,
            onDoubleClick: openSelection
        )
        .overlay {
            if results.isEmpty {
                ContentUnavailableView(
                    isSearching ? "Searching…" : "No Results",
                    systemImage: isSearching ? "magnifyingglass" : "doc.text.magnifyingglass",
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("Searched \(searchedCount) of \(totalCount) processes")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(results.count) matches")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { openSelection() }
                .disabled(selectedResult == nil)
            Button("Close") {
                stopSearch()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var emptyDescription: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter text to find matching mapped images or handles."
        }
        return isSearching ? "Matches appear as they are found." : "No mapped image or handle path matched."
    }

    private var selectedResult: FindHandleDLLResult? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    private func startSearch() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        searchTask?.cancel()
        results = []
        selectedID = nil
        searchedCount = 0
        totalCount = model.snapshot.processes.count
        isSearching = true

        let processes = model.snapshot.processes.values.sorted { $0.id.pid < $1.id.pid }
        let data = model.data
        searchTask = Task { @MainActor in
            for record in processes {
                guard !Task.isCancelled else { break }
                await search(record: record, needle: needle, data: data)
                searchedCount += 1
            }
            isSearching = false
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func search(record: ProcessRecord, needle: String, data: any ProcessDataProviding) async {
        let query = needle.lowercased()
        if let modules = try? await data.modules(of: record.id) {
            for module in modules where matches(module: module, query: query) {
                results.append(FindHandleDLLResult(
                    kind: .dll,
                    pid: record.id,
                    processName: record.name,
                    name: module.name,
                    path: module.path
                ))
            }
        }
        if let handles = try? await data.fileDescriptors(of: record.id) {
            for handle in handles where matches(handle: handle, query: query) {
                results.append(FindHandleDLLResult(
                    kind: .handle,
                    pid: record.id,
                    processName: record.name,
                    name: handle.kind.rawValue,
                    path: handle.name
                ))
            }
        }
    }

    private func matches(module: ModuleInfo, query: String) -> Bool {
        module.path.lowercased().contains(query) || module.name.lowercased().contains(query)
    }

    private func matches(handle: FileDescriptorInfo, query: String) -> Bool {
        handle.name.lowercased().contains(query) || handle.kind.rawValue.lowercased().contains(query)
    }

    private func openSelection() {
        guard let result = selectedResult else { return }
        model.selection = result.pid
        model.showLowerPane = true
        model.lowerPaneMode = result.kind == .dll ? .modules : .handles
    }
}

private struct FindHandleDLLResult: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case dll
        case handle

        var title: String {
            switch self {
            case .dll: return "DLL"
            case .handle: return "Handle"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let pid: ProcessID
    let processName: String
    let name: String
    let path: String

    var typeText: String {
        switch kind {
        case .dll: return "DLL"
        case .handle: return name
        }
    }
}

private struct FindResultsTable: NSViewRepresentable {
    let results: [FindHandleDLLResult]
    @Binding var selection: FindHandleDLLResult.ID?
    var onDoubleClick: () -> Void

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
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(Coordinator.doubleClick(_:))
        tableView.target = context.coordinator
        tableView.typeSelectHandler = { text in
            context.coordinator.handleTypeSelect(text)
        }
        for column in Coordinator.columns {
            tableView.addTableColumn(column.tableColumn)
        }
        TableColumnPersistence.apply(to: tableView, key: Coordinator.persistenceKey)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.results = results
        context.coordinator.onDoubleClick = onDoubleClick
        guard let tableView = context.coordinator.tableView else { return }
        tableView.reloadData()
        if let selection, let row = results.firstIndex(where: { $0.id == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
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
                column.minWidth = min(width, 50)
                column.resizingMask = [.userResizingMask, .autoresizingMask]
                return column
            }
        }

        static let columns = [
            ColumnDef(id: "process", title: "Process", width: 190, alignment: .left),
            ColumnDef(id: "pid", title: "PID", width: 70, alignment: .right),
            ColumnDef(id: "type", title: "Type", width: 90, alignment: .left),
            ColumnDef(id: "name", title: "Name", width: 480, alignment: .left),
        ]
        static let persistenceKey = "findHandleDLL.columns"

        var results: [FindHandleDLLResult] = []
        var selection: Binding<FindHandleDLLResult.ID?>
        var onDoubleClick: () -> Void
        weak var tableView: NSTableView?
        private let typeSelectBuffer = TypeSelectBuffer()

        init(selection: Binding<FindHandleDLLResult.ID?>, onDoubleClick: @escaping () -> Void) {
            self.selection = selection
            self.onDoubleClick = onDoubleClick
        }

        func numberOfRows(in tableView: NSTableView) -> Int { results.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard results.indices.contains(row), let tableColumn else { return nil }
            let id = tableColumn.identifier.rawValue
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(id: tableColumn.identifier)
            configure(cell: cell, text: text(for: id, result: results[row]), alignment: alignment(for: id))
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
            for result in results {
                width = max(width, ceil((text(for: id, result: result) as NSString).size(withAttributes: valueAttributes).width) + 12)
            }
            return width
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            selection.wrappedValue = results.indices.contains(row) ? results[row].id : nil
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            TableColumnPersistence.save(from: tableView, key: Self.persistenceKey)
        }

        func handleTypeSelect(_ text: String) -> Bool {
            let prefix = typeSelectBuffer.append(text)
            if selectNext(matching: prefix) { return true }
            return selectNext(matching: typeSelectBuffer.reset(to: text))
        }

        private func selectNext(matching prefix: String) -> Bool {
            guard !results.isEmpty, let tableView else { return false }
            let start = tableView.selectedRow >= 0 ? tableView.selectedRow : -1
            for offset in 1...results.count {
                let index = (start + offset) % results.count
                let result = results[index]
                if result.processName.lowercased().hasPrefix(prefix)
                    || result.typeText.lowercased().hasPrefix(prefix)
                    || result.path.lowercased().hasPrefix(prefix) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                    selection.wrappedValue = result.id
                    return true
                }
            }
            return false
        }

        @objc func doubleClick(_ sender: NSTableView) {
            guard results.indices.contains(sender.clickedRow) else { return }
            onDoubleClick()
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
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
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

        private func text(for id: String, result: FindHandleDLLResult) -> String {
            switch id {
            case "process": return result.processName
            case "pid": return String(result.pid.pid)
            case "type": return result.typeText
            case "name": return result.path
            default: return ""
            }
        }

        private func alignment(for id: String) -> NSTextAlignment {
            Self.columns.first { $0.id == id }?.alignment ?? .left
        }
    }
}