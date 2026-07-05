//
//  ProcessOutlineView.swift
//  Frozen-column custom process list.
//
//  The process tree and metric columns are custom-drawn, but they are split
//  into separate panes so the Process column has its own horizontal scrollbar
//  and the column headers are outside the vertically scrolling row views.
//

import AppKit
import SwiftUI
import ProcexpModel

enum ProcessCommand: Sendable {
    case kill
    case killTree
    case suspendResume
    case setNice(Int32)
    case bringToFront
    case restart
    case sample
    case searchOnline
    case checkVirusTotal
    case properties
    case copy
}

@MainActor
struct ProcessOutlineView: NSViewRepresentable {
    let model: AppModel
    let snapshot: ProcessSnapshot
    let columns: [Column]
    let colorRules: [ProcessColorRule]
    let treeMode: Bool
    let treeSortResetToken: Int
    let searchText: String
    var onCommand: (ProcessCommand, ProcessID) -> Void

    func makeNSView(context: Context) -> ProcessListContainerView {
        let coordinator = context.coordinator
        let container = ProcessListContainerView(frame: .zero)
        container.configure(coordinator: coordinator, processPaneWidth: CGFloat(model.processColumnWidth))
        coordinator.containerView = container
        coordinator.processHeaderView = container.processHeaderView
        coordinator.metricsHeaderView = container.metricsHeaderView
        coordinator.processRowsView = container.processRowsView
        coordinator.metricsRowsView = container.metricsRowsView
        coordinator.processBodyScrollView = container.processBodyScrollView
        coordinator.metricsHeaderScrollView = container.metricsHeaderScrollView
        coordinator.metricsBodyScrollView = container.metricsBodyScrollView
        coordinator.installColumns(columns)
        coordinator.installMenus()
        coordinator.installScrollSync()
        coordinator.update(snapshot: snapshot, columns: columns, colorRules: colorRules, treeMode: treeMode, treeSortResetToken: treeSortResetToken, searchText: searchText)
        return container
    }

    func updateNSView(_ nsView: ProcessListContainerView, context: Context) {
        context.coordinator.onCommand = onCommand
        context.coordinator.update(snapshot: snapshot, columns: columns, colorRules: colorRules, treeMode: treeMode, treeSortResetToken: treeSortResetToken, searchText: searchText)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onCommand: onCommand)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        static let rowHeight: CGFloat = 17
        static let headerHeight: CGFloat = 22
        static let defaultProcessPaneWidth: CGFloat = 430
        static let minProcessPaneWidth: CGFloat = 220
        static let minMetricColumnWidth: CGFloat = 42
        static let indentationPerLevel: CGFloat = 14
        static let iconSize: CGFloat = 15
        static let gridNSColor = NSColor(white: 0.5, alpha: 0.18)

        let model: AppModel
        var onCommand: (ProcessCommand, ProcessID) -> Void

        weak var containerView: ProcessListContainerView?
        weak var processHeaderView: ProcessListSurfaceView?
        weak var metricsHeaderView: ProcessListSurfaceView?
        weak var processRowsView: ProcessListSurfaceView?
        weak var metricsRowsView: ProcessListSurfaceView?
        weak var processBodyScrollView: ProcessPaneScrollView?
        weak var metricsHeaderScrollView: NSScrollView?
        weak var metricsBodyScrollView: ProcessPaneScrollView?

        private var snapshot: ProcessSnapshot = .empty
        private var displayRoots: [ProcessID] = []
        private var displayChildren: [ProcessID: [ProcessID]] = [:]
        private var visibleRows: [VisibleProcessRow] = []
        private var iconCache: [String: NSImage] = [:]
        private var processHighlights: [ProcessID: TimedListRowHighlight] = [:]
        private var removedProcessRecords: [ProcessID: ProcessRecord] = [:]
        private var expanded: Set<ProcessID> = []
        private var currentColumns: [Column] = []
        private var metricColumnWidths: [Column: CGFloat] = [:]
        private var currentRules: [ProcessColorRule] = []
        private var currentTreeMode = true
        private var currentTreeSortResetToken = 0
        private var currentSearchText = ""
        private var lastRestoredSelection: ProcessID?
        private var sortColumn: Column?
        private var sortAscending = true
        private var didInitialExpand = false
        private var didResetInitialScroll = false
        private var processPaneWidth = defaultProcessPaneWidth
        private var cachedProcessRequiredWidth = defaultProcessPaneWidth
        private var cachedProcessContentWidth = defaultProcessPaneWidth
        private var maxVisiblePrivateBytes: UInt64 = 0
        private var maxVisibleWorkingSet: UInt64 = 0
        private var commandLineCache: [ProcessID: String] = [:]
        private var commandLineInFlight: Set<ProcessID> = []
        private var suppressScrollSync = false
        private var scrollObservers: [NSObjectProtocol] = []
        private var activeResize: ColumnResizeState?
        private var activeColumnDrag: ColumnDragState?
        private let typeSelectBuffer = TypeSelectBuffer()

        private let columnsMenu = NSMenu(title: "Select Columns")
        private let rowMenu = NSMenu(title: "Process")

        init(model: AppModel, onCommand: @escaping (ProcessCommand, ProcessID) -> Void) {
            self.model = model
            self.onCommand = onCommand
            self.processPaneWidth = CGFloat(model.processColumnWidth)
            self.cachedProcessContentWidth = CGFloat(model.processColumnWidth)
        }

        deinit {
            for observer in scrollObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func update(snapshot newSnapshot: ProcessSnapshot,
                    columns: [Column],
                    colorRules: [ProcessColorRule],
                    treeMode: Bool,
                    treeSortResetToken: Int,
                    searchText: String) {
            let shouldAutoExpand = !newSnapshot.processes.isEmpty && (!didInitialExpand || snapshot.processes.isEmpty)
            if columns != currentColumns {
                installColumns(columns)
            }
            currentRules = colorRules
            currentTreeMode = treeMode
            if treeSortResetToken != currentTreeSortResetToken {
                currentTreeSortResetToken = treeSortResetToken
                sortColumn = nil
                sortAscending = true
            }
            currentSearchText = searchText
            updateProcessHighlights(from: snapshot, to: newSnapshot)
            snapshot = newSnapshot
            rebuildDisplayTree()
            if shouldAutoExpand {
                didInitialExpand = true
                expanded = Set(snapshot.processes.keys)
            } else {
                expanded = expanded.filter { snapshot.processes[$0] != nil }
                expanded.formUnion(processHighlights.compactMap { $0.value.kind == .new ? $0.key : nil })
            }
            rebuildVisibleRows()
            rebuildProcessWidthCache()
            rebuildUsageMaxima()
            updateCanvasFrames()
            if shouldAutoExpand && !didResetInitialScroll {
                didResetInitialScroll = true
                scrollToOrigin()
            }
            restoreSelection()
        }

        func installColumns(_ columns: [Column]) {
            let requested = columns.isEmpty ? Column.defaultColumns : columns
            currentColumns = [.name] + requested.filter { $0 != .name }
            for column in currentColumns where column != .name && metricColumnWidths[column] == nil {
                metricColumnWidths[column] = model.columnWidths[column.rawValue].map { CGFloat($0) } ?? column.defaultWidth
            }
        }

        private func updateProcessHighlights(from oldSnapshot: ProcessSnapshot, to newSnapshot: ProcessSnapshot) {
            let now = Date()
            processHighlights = processHighlights.filter { $0.value.expiresAt > now }
            removedProcessRecords = removedProcessRecords.filter { processHighlights[$0.key]?.kind == .deleted }
            guard !oldSnapshot.processes.isEmpty else { return }
            let expiry = now.addingTimeInterval(max(0.2, model.differenceHighlightDuration))
            let diff = SnapshotDiff.between(oldSnapshot, newSnapshot)
            for id in diff.added {
                processHighlights[id] = TimedListRowHighlight(kind: .new, expiresAt: expiry)
            }
            for id in diff.removed {
                if let record = oldSnapshot.processes[id] {
                    removedProcessRecords[id] = record
                    processHighlights[id] = TimedListRowHighlight(kind: .deleted, expiresAt: expiry)
                }
            }
        }

        func installMenus() {
            columnsMenu.delegate = self
            columnsMenu.autoenablesItems = false

            rowMenu.delegate = self
            rowMenu.autoenablesItems = false
            func add(_ title: String, _ selector: Selector) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                rowMenu.addItem(item)
            }
            add("Kill Process", #selector(menuKill(_:)))
            add("Kill Process Tree", #selector(menuKillTree(_:)))
            add("Suspend / Resume", #selector(menuSuspendResume(_:)))
            rowMenu.addItem(.separator())

            let priorityItem = NSMenuItem(title: "Set Priority", action: nil, keyEquivalent: "")
            let priorityMenu = NSMenu()
            for (title, nice) in [("Idle (19)", 19), ("Below Normal (10)", 10), ("Normal (0)", 0), ("Above Normal (-10)", -10), ("High (-20)", -20)] {
                let item = NSMenuItem(title: title, action: #selector(menuSetNice(_:)), keyEquivalent: "")
                item.target = self
                item.tag = nice
                priorityMenu.addItem(item)
            }
            priorityItem.submenu = priorityMenu
            rowMenu.addItem(priorityItem)
            add("Bring to Front", #selector(menuBringToFront(_:)))
            add("Restart", #selector(menuRestart(_:)))
            add("Sample Process…", #selector(menuSample(_:)))
            rowMenu.addItem(.separator())
            add("Search Online", #selector(menuSearchOnline(_:)))
            add("Check VirusTotal", #selector(menuCheckVirusTotal(_:)))
            rowMenu.addItem(.separator())
            add("Properties...", #selector(menuProperties(_:)))
            add("Copy", #selector(menuCopy(_:)))
        }

        func installScrollSync() {
            processBodyScrollView?.syncClipView.coordinator = self
            processBodyScrollView?.syncClipView.source = .processRows
            processBodyScrollView?.isProcessPane = true
            metricsBodyScrollView?.syncClipView.coordinator = self
            metricsBodyScrollView?.syncClipView.source = .metricsRows
            metricsBodyScrollView?.isProcessPane = false
        }

        func syncScroll(from source: ProcessScrollSource) {
            guard !suppressScrollSync else { return }
            suppressScrollSync = true
            defer { suppressScrollSync = false }

            switch source {
            case .processRows:
                guard let processClip = processBodyScrollView?.contentView,
                      let metricsBodyScrollView else { return }
                var target = metricsBodyScrollView.contentView.bounds.origin
                target.y = processClip.bounds.origin.y
                metricsBodyScrollView.contentView.scroll(to: target)
                metricsBodyScrollView.reflectScrolledClipView(metricsBodyScrollView.contentView)
            case .metricsRows:
                guard let metricsClip = metricsBodyScrollView?.contentView else { return }
                if let processBodyScrollView {
                    var target = processBodyScrollView.contentView.bounds.origin
                    target.y = metricsClip.bounds.origin.y
                    processBodyScrollView.contentView.scroll(to: target)
                    processBodyScrollView.reflectScrolledClipView(processBodyScrollView.contentView)
                }
                if let metricsHeaderScrollView {
                    var target = metricsHeaderScrollView.contentView.bounds.origin
                    target.x = metricsClip.bounds.origin.x
                    metricsHeaderScrollView.contentView.scroll(to: target)
                    metricsHeaderScrollView.reflectScrolledClipView(metricsHeaderScrollView.contentView)
                }
            }
        }

        func forwardProcessWheelToMetrics(_ event: NSEvent) {
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                  let metricsBodyScrollView else { return }
            metricsBodyScrollView.scrollWheel(with: event)
        }

        func resizeProcessPane(to proposedWidth: CGFloat) {
            guard let containerView else { return }
            let maxWidth = max(Self.minProcessPaneWidth, containerView.bounds.width - 260)
            processPaneWidth = min(max(proposedWidth, Self.minProcessPaneWidth), maxWidth)
            cachedProcessContentWidth = max(processPaneWidth, cachedProcessRequiredWidth)
            model.processColumnWidth = Double(processPaneWidth)
            containerView.setProcessPaneWidth(processPaneWidth)
            updateCanvasFrames()
        }

        func updateCanvasFrames() {
            let rowHeight = CGFloat(max(visibleRows.count, 1)) * Self.rowHeight
            let processWidth = cachedProcessContentWidth
            let metricsWidth = max(metricContentWidth(), metricsBodyScrollView?.contentView.bounds.width ?? 0)

            setFrameSize(NSSize(width: processPaneWidth, height: Self.headerHeight), for: processHeaderView)
            setFrameSize(NSSize(width: processWidth, height: rowHeight), for: processRowsView)
            setFrameSize(NSSize(width: metricsWidth, height: Self.headerHeight), for: metricsHeaderView)
            setFrameSize(NSSize(width: metricsWidth, height: rowHeight), for: metricsRowsView)
            updateScrollerVisibility(rowHeight: rowHeight, processWidth: processWidth, metricsWidth: metricsWidth)
        }

        private func updateScrollerVisibility(rowHeight: CGFloat, processWidth: CGFloat, metricsWidth: CGFloat) {
            if let processBodyScrollView {
                let needsHorizontal = processWidth > processBodyScrollView.contentView.bounds.width + 0.5
                if processBodyScrollView.hasHorizontalScroller != needsHorizontal {
                    processBodyScrollView.hasHorizontalScroller = needsHorizontal
                }
                if !needsHorizontal, processBodyScrollView.contentView.bounds.origin.x != 0 {
                    processBodyScrollView.contentView.scroll(to: NSPoint(x: 0, y: processBodyScrollView.contentView.bounds.origin.y))
                    processBodyScrollView.reflectScrolledClipView(processBodyScrollView.contentView)
                }
            }
            if let metricsBodyScrollView {
                let needsHorizontal = metricsWidth > metricsBodyScrollView.contentView.bounds.width + 0.5
                let needsVertical = rowHeight > metricsBodyScrollView.contentView.bounds.height + 0.5
                if metricsBodyScrollView.hasHorizontalScroller != needsHorizontal {
                    metricsBodyScrollView.hasHorizontalScroller = needsHorizontal
                }
                if metricsBodyScrollView.hasVerticalScroller != needsVertical {
                    metricsBodyScrollView.hasVerticalScroller = needsVertical
                }
                if !needsHorizontal, metricsBodyScrollView.contentView.bounds.origin.x != 0 {
                    metricsBodyScrollView.contentView.scroll(to: NSPoint(x: 0, y: metricsBodyScrollView.contentView.bounds.origin.y))
                    metricsBodyScrollView.reflectScrolledClipView(metricsBodyScrollView.contentView)
                }
            }
            if let metricsHeaderScrollView,
               metricsHeaderScrollView.contentView.bounds.origin.x != (metricsBodyScrollView?.contentView.bounds.origin.x ?? 0) {
                let x = metricsBodyScrollView?.contentView.bounds.origin.x ?? 0
                metricsHeaderScrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
                metricsHeaderScrollView.reflectScrolledClipView(metricsHeaderScrollView.contentView)
            }
        }

        private func setFrameSize(_ size: NSSize, for view: NSView?) {
            guard let view, view.frame.size != size else { return }
            view.setFrameSize(size)
            view.needsDisplay = true
        }

        private func scrollToOrigin() {
            if let processBodyScrollView {
                processBodyScrollView.contentView.scroll(to: .zero)
                processBodyScrollView.reflectScrolledClipView(processBodyScrollView.contentView)
            }
            if let metricsBodyScrollView {
                metricsBodyScrollView.contentView.scroll(to: .zero)
                metricsBodyScrollView.reflectScrolledClipView(metricsBodyScrollView.contentView)
            }
            if let metricsHeaderScrollView {
                metricsHeaderScrollView.contentView.scroll(to: .zero)
                metricsHeaderScrollView.reflectScrolledClipView(metricsHeaderScrollView.contentView)
            }
        }

        private func invalidateAll() {
            processHeaderView?.needsDisplay = true
            metricsHeaderView?.needsDisplay = true
            processRowsView?.needsDisplay = true
            metricsRowsView?.needsDisplay = true
        }

        private var metricColumns: [Column] {
            currentColumns.filter { $0 != .name }
        }

        private func metricContentWidth() -> CGFloat {
            metricColumns.reduce(CGFloat(0)) { $0 + width(for: $1) }
        }

        private func width(for column: Column) -> CGFloat {
            metricColumnWidths[column] ?? column.defaultWidth
        }

        private func processContentWidth() -> CGFloat {
            cachedProcessContentWidth
        }

        private var regularTextAttributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        }

        private var boldTextAttributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)]
        }

        private var numericTextAttributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)]
        }

        private func rebuildProcessWidthCache() {
            var width = Self.minProcessPaneWidth
            let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            for row in visibleRows {
                guard let record = snapshot.processes[row.id] else { continue }
                let textWidth = (record.name as NSString).size(withAttributes: [.font: font]).width
                let rowWidth = 5 + CGFloat(row.depth) * Self.indentationPerLevel + 13 + Self.iconSize + 5 + textWidth + 16
                width = max(width, ceil(rowWidth))
            }
            cachedProcessRequiredWidth = width
            cachedProcessContentWidth = max(processPaneWidth, width)
        }

        private func rebuildUsageMaxima() {
            var privateMax: UInt64 = 0
            var workingSetMax: UInt64 = 0
            for row in visibleRows {
                guard let record = snapshot.processes[row.id] else { continue }
                privateMax = max(privateMax, record.physFootprint ?? record.residentSize)
                workingSetMax = max(workingSetMax, record.residentSize)
            }
            maxVisiblePrivateBytes = privateMax
            maxVisibleWorkingSet = workingSetMax
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === rowMenu {
                updateProcessMenuItemsEnabled(clickedProcessID() != nil, in: rowMenu)
                return
            }
            guard menu === columnsMenu else { return }
            menu.removeAllItems()
            let shown = Set(currentColumns)
            for column in Column.supportedOnMac {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = shown.contains(column) ? .on : .off
                item.isEnabled = column != .name && column != .pid
                menu.addItem(item)
            }
        }

        private func updateProcessMenuItemsEnabled(_ enabled: Bool, in menu: NSMenu) {
            for item in menu.items where !item.isSeparatorItem {
                item.isEnabled = enabled
                if let submenu = item.submenu {
                    updateProcessMenuItemsEnabled(enabled, in: submenu)
                }
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                let column = Column(rawValue: raw), column != .name, column != .pid else { return }
            var columns = model.columns
            if let index = columns.firstIndex(of: column) {
                columns.remove(at: index)
            } else {
                columns.append(column)
            }
            model.columns = columns
            installColumns(columns)
            updateCanvasFrames()
        }

        private func rebuildDisplayTree() {
            let query = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let allProcesses = displayedProcesses()
            let visible: Set<ProcessID> = query.isEmpty ? Set(allProcesses.keys) : visibleSet(matching: query)
            displayChildren.removeAll(keepingCapacity: true)
            guard currentTreeMode, sortColumn == nil else {
                displayRoots = sorted(Array(visible))
                return
            }
            for (parent, children) in snapshot.children {
                let filtered = children.filter { visible.contains($0) }
                if !filtered.isEmpty { displayChildren[parent] = sorted(filtered) }
            }
            for (id, record) in removedProcessRecords where visible.contains(id) {
                if let parent = record.parent, visible.contains(parent) {
                    displayChildren[parent, default: []].append(id)
                    displayChildren[parent] = sorted(Array(Set(displayChildren[parent] ?? [])))
                }
            }
            let roots = snapshot.roots.filter { visible.contains($0) }
            if roots.isEmpty, !visible.isEmpty {
                displayRoots = sorted(visible.filter { pid in
                    guard let record = allProcesses[pid] else { return false }
                    guard let parent = record.parent else { return true }
                    return parent == pid || !visible.contains(parent)
                })
            } else {
                let ghostRoots = removedProcessRecords.keys.filter { id in
                    guard visible.contains(id), let record = removedProcessRecords[id] else { return false }
                    guard let parent = record.parent else { return true }
                    return parent == id || !visible.contains(parent)
                }
                displayRoots = sorted(Array(Set(roots + ghostRoots)))
            }
        }

        private func displayedProcesses() -> [ProcessID: ProcessRecord] {
            var processes = snapshot.processes
            for (id, record) in removedProcessRecords {
                processes[id] = record
            }
            return processes
        }

        private func visibleSet(matching query: String) -> Set<ProcessID> {
            var visible = Set<ProcessID>()
            let processes = displayedProcesses()
            for (pid, record) in processes {
                if record.name.lowercased().contains(query) || String(pid.pid).contains(query) {
                    visible.insert(pid)
                    var ancestor = record.parent
                    while let current = ancestor, processes[current] != nil, !visible.contains(current) {
                        visible.insert(current)
                        ancestor = processes[current]?.parent
                    }
                }
            }
            return visible
        }

        private func sorted(_ ids: [ProcessID]) -> [ProcessID] {
            guard let sortColumn else { return ids.sorted { $0.pid < $1.pid } }
            let processes = displayedProcesses()
            return ids.sorted { lhs, rhs in
                guard let left = processes[lhs], let right = processes[rhs] else { return lhs.pid < rhs.pid }
                let leftKey = sortColumn.sortValue(for: left)
                let rightKey = sortColumn.sortValue(for: right)
                if leftKey == rightKey { return lhs.pid < rhs.pid }
                return sortAscending ? leftKey < rightKey : rightKey < leftKey
            }
        }

        private func rebuildVisibleRows() {
            visibleRows.removeAll(keepingCapacity: true)
            for root in displayRoots {
                appendVisibleRow(root, depth: 0)
            }
        }

        private func appendVisibleRow(_ pid: ProcessID, depth: Int) {
            guard displayedProcesses()[pid] != nil else { return }
            visibleRows.append(VisibleProcessRow(id: pid, depth: depth))
            guard currentTreeMode, expanded.contains(pid) else { return }
            for child in displayChildren[pid] ?? [] {
                appendVisibleRow(child, depth: depth + 1)
            }
        }

        private func restoreSelection() {
            if let selection = model.selection, snapshot.processes[selection] == nil {
                model.selection = nil
            }
            let selectionChanged = model.selection != lastRestoredSelection
            lastRestoredSelection = model.selection
            if selectionChanged, let selection = model.selection {
                if visibleRows.firstIndex(where: { $0.id == selection }) == nil {
                    expandAncestors(of: selection)
                    rebuildVisibleRows()
                    rebuildProcessWidthCache()
                    rebuildUsageMaxima()
                    updateCanvasFrames()
                }
                scrollSelectionToVisible()
            }
            invalidateAll()
        }

        func draw(surface: ProcessListSurfaceView, dirtyRect: NSRect) {
            switch surface.kind {
            case .processHeader:
                drawProcessHeader(in: surface, dirtyRect: dirtyRect)
            case .metricsHeader:
                drawMetricsHeader(in: surface, dirtyRect: dirtyRect)
            case .processRows:
                drawProcessRows(in: surface, dirtyRect: dirtyRect)
            case .metricsRows:
                drawMetricsRows(in: surface, dirtyRect: dirtyRect)
            }
        }

        private func drawProcessHeader(in view: NSView, dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            drawHeaderTitle(.name, in: NSRect(x: 8, y: 2, width: processPaneWidth - 16, height: Self.headerHeight - 4))
            drawBottomBorder(in: view.bounds)
        }

        private func drawMetricsHeader(in view: NSView, dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            var x: CGFloat = 0
            for column in metricColumns {
                let width = width(for: column)
                let rect = NSRect(x: x, y: 0, width: width, height: Self.headerHeight)
                if rect.intersects(dirtyRect) {
                    drawUsageHeaderBackground(for: column, in: rect)
                    drawHeaderTitle(column, in: rect.insetBy(dx: 4, dy: 2))
                    drawVerticalBorder(x: rect.maxX - 0.5, minY: rect.minY, maxY: rect.maxY)
                }
                x += width
            }
            drawBottomBorder(in: NSRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: Self.headerHeight))
        }

        private func drawProcessRows(in view: ProcessListSurfaceView, dirtyRect: NSRect) {
            drawRowBackground(dirtyRect)
            guard let range = visibleRowRange(in: dirtyRect) else { return }
            let dark = isDarkMode(view)
            for rowIndex in range {
                let row = visibleRows[rowIndex]
                guard let record = displayedProcesses()[row.id] else { continue }
                let rowRect = NSRect(x: dirtyRect.minX, y: CGFloat(rowIndex) * Self.rowHeight, width: dirtyRect.width, height: Self.rowHeight)
                drawRowFill(row.id, rowRect: rowRect, dark: dark)
                drawProcessCell(row: row, record: record, rowRect: rowRect)
            }
        }

        private func drawMetricsRows(in view: ProcessListSurfaceView, dirtyRect: NSRect) {
            drawRowBackground(dirtyRect)
            guard let range = visibleRowRange(in: dirtyRect) else { return }
            let dark = isDarkMode(view)
            for rowIndex in range {
                let row = visibleRows[rowIndex]
                guard let record = displayedProcesses()[row.id] else { continue }
                let rowRect = NSRect(x: dirtyRect.minX, y: CGFloat(rowIndex) * Self.rowHeight, width: dirtyRect.width, height: Self.rowHeight)
                drawRowFill(row.id, rowRect: rowRect, dark: dark)
                drawMetricCells(for: record, rowRect: rowRect, dirtyRect: dirtyRect)
            }
        }

        private func drawRowBackground(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
        }

        private func visibleRowRange(in dirtyRect: NSRect) -> ClosedRange<Int>? {
            guard !visibleRows.isEmpty else { return nil }
            let start = max(0, Int(floor(dirtyRect.minY / Self.rowHeight)))
            let end = min(visibleRows.count - 1, Int(ceil(dirtyRect.maxY / Self.rowHeight)))
            guard start <= end else { return nil }
            return start...end
        }

        private func drawRowFill(_ id: ProcessID, rowRect: NSRect, dark: Bool) {
            if let color = rowColor(for: id, dark: dark) {
                color.setFill()
                rowRect.fill()
            }
            if model.selection == id {
                NSColor.selectedContentBackgroundColor.setFill()
                rowRect.fill()
            }
        }

        private func drawProcessCell(row: VisibleProcessRow, record: ProcessRecord, rowRect: NSRect) {
            let disclosureX = 5 + CGFloat(row.depth) * Self.indentationPerLevel
            if isExpandable(row.id) {
                drawDisclosure(expanded: expanded.contains(row.id), x: disclosureX, y: rowRect.midY)
            }
            let iconX = disclosureX + 13
            icon(for: record).draw(in: NSRect(x: iconX, y: rowRect.minY + 1, width: Self.iconSize, height: Self.iconSize),
                                   from: .zero,
                                   operation: .sourceOver,
                                   fraction: 1,
                                   respectFlipped: true,
                                   hints: nil)
            drawText(record.name,
                     in: NSRect(x: iconX + Self.iconSize + 5,
                                y: rowRect.minY + 1,
                                width: max(0, processContentWidth() - iconX - Self.iconSize - 9),
                                height: rowRect.height - 2),
                     rightAligned: false,
                     selected: model.selection == row.id)
        }

        private func drawMetricCells(for record: ProcessRecord, rowRect: NSRect, dirtyRect: NSRect) {
            var x: CGFloat = 0
            for column in metricColumns {
                let width = width(for: column)
                let rect = NSRect(x: x, y: rowRect.minY, width: width, height: rowRect.height)
                if rect.intersects(dirtyRect) {
                    if plainMetricBackground(for: column), model.selection != record.id {
                        NSColor.textBackgroundColor.setFill()
                        rect.fill()
                        drawUsageCellBackground(for: column, record: record, in: rect)
                    }
                    drawText(column.string(for: record),
                             in: rect.insetBy(dx: 4, dy: 1),
                             rightAligned: column.isRightAligned,
                             selected: model.selection == record.id)
                    drawVerticalBorder(x: rect.maxX - 0.5, minY: rowRect.minY, maxY: rowRect.maxY)
                }
                x += width
            }
        }

        private func drawHeaderTitle(_ column: Column, in rect: NSRect) {
            var title = column.title
            if sortColumn == column {
                title += sortAscending ? " ^" : " v"
            }
            drawText(title, in: rect, rightAligned: column.isRightAligned, selected: false, bold: true)
        }

        private func drawText(_ text: String, in rect: NSRect, rightAligned: Bool, selected: Bool, bold: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = rightAligned ? .right : .left
            paragraph.lineBreakMode = .byTruncatingTail
            let font: NSFont = rightAligned && !bold
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize, weight: bold ? .semibold : .regular)
            let color: NSColor = selected ? .white : .labelColor
            (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }

        private func drawDisclosure(expanded: Bool, x: CGFloat, y: CGFloat) {
            let path = NSBezierPath()
            if expanded {
                path.move(to: NSPoint(x: x, y: y - 2))
                path.line(to: NSPoint(x: x + 7, y: y - 2))
                path.line(to: NSPoint(x: x + 3.5, y: y + 3))
            } else {
                path.move(to: NSPoint(x: x + 1, y: y - 5))
                path.line(to: NSPoint(x: x + 1, y: y + 5))
                path.line(to: NSPoint(x: x + 7, y: y))
            }
            path.close()
            NSColor.secondaryLabelColor.setFill()
            path.fill()
        }

        private func drawBottomBorder(in rect: NSRect) {
            drawHorizontalBorder(rect.maxY - 0.5, minX: rect.minX, maxX: rect.maxX)
        }

        private func drawHorizontalBorder(_ y: CGFloat, minX: CGFloat, maxX: CGFloat) {
            Self.gridNSColor.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: minX, y: y), to: NSPoint(x: maxX, y: y))
        }

        private func drawVerticalBorder(x: CGFloat, minY: CGFloat, maxY: CGFloat) {
            Self.gridNSColor.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: minY), to: NSPoint(x: x, y: maxY))
        }

        func handleMouseDown(in kind: ProcessListSurfaceKind, at point: NSPoint, clickCount: Int) {
            switch kind {
            case .processHeader:
                if clickCount == 2, autoFitDividerIfNeeded(kind: kind, at: point) { return }
                if beginResizeIfNeeded(kind: kind, at: point) { return }
                cycleProcessColumnSort()
            case .metricsHeader:
                if clickCount == 2, autoFitDividerIfNeeded(kind: kind, at: point) { return }
                if beginResizeIfNeeded(kind: kind, at: point) { return }
                beginColumnDragIfNeeded(at: point)
            case .processRows, .metricsRows:
                guard let rowIndex = rowIndex(at: point), visibleRows.indices.contains(rowIndex) else { return }
                let row = visibleRows[rowIndex]
                if kind == .processRows, clickedDisclosure(at: point, row: row) {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    rebuildVisibleRows()
                    rebuildProcessWidthCache()
                    rebuildUsageMaxima()
                    updateCanvasFrames()
                    return
                }
                model.selection = row.id
                invalidateAll()
                if clickCount == 2 { onCommand(.properties, row.id) }
            }
        }

        func handleMouseDragged(in kind: ProcessListSurfaceKind, at point: NSPoint) {
            if let activeResize {
                switch activeResize.target {
                case .process:
                    resizeProcessPane(to: activeResize.startWidth + point.x - activeResize.startX)
                case .metric(let column):
                    let proposed = activeResize.startWidth + point.x - activeResize.startX
                    metricColumnWidths[column] = max(Self.minMetricColumnWidth, proposed)
                    persistMetricColumnWidth(column)
                    updateCanvasFrames()
                }
                return
            }
            guard kind == .metricsHeader, var activeColumnDrag else { return }
            if abs(point.x - activeColumnDrag.startX) > 4 {
                activeColumnDrag.didMove = true
            }
            guard activeColumnDrag.didMove else {
                self.activeColumnDrag = activeColumnDrag
                return
            }
            let targetIndex = metricColumnInsertionIndex(at: point.x, excluding: activeColumnDrag.column)
            moveMetricColumn(activeColumnDrag.column, toMetricIndex: targetIndex)
            self.activeColumnDrag = activeColumnDrag
        }

        func handleMouseUp(in kind: ProcessListSurfaceKind, at point: NSPoint) {
            if let activeColumnDrag, !activeColumnDrag.didMove {
                sort(by: activeColumnDrag.column)
            }
            activeResize = nil
            activeColumnDrag = nil
        }

        func updateCursorRects(for surface: ProcessListSurfaceView) {
            switch surface.kind {
            case .processHeader:
                surface.addCursorRect(NSRect(x: max(0, processPaneWidth - 4), y: 0, width: 8, height: Self.headerHeight), cursor: .resizeLeftRight)
            case .metricsHeader:
                for rect in metricResizeRects() {
                    surface.addCursorRect(rect, cursor: .resizeLeftRight)
                }
            case .processRows, .metricsRows:
                break
            }
        }

        func handleRightMouseDown(in kind: ProcessListSurfaceKind, at point: NSPoint) -> NSMenu? {
            switch kind {
            case .processHeader, .metricsHeader:
                return columnsMenu
            case .processRows, .metricsRows:
                if let rowIndex = rowIndex(at: point), visibleRows.indices.contains(rowIndex) {
                    model.selection = visibleRows[rowIndex].id
                    invalidateAll()
                }
                return rowMenu
            }
        }

        func moveSelection(delta: Int) {
            guard !visibleRows.isEmpty else { return }
            let current = model.selection.flatMap { selection in visibleRows.firstIndex { $0.id == selection } } ?? 0
            let next = min(max(current + delta, 0), visibleRows.count - 1)
            model.selection = visibleRows[next].id
            scrollRowToVisible(next)
            invalidateAll()
        }

        func handleTypeSelect(_ text: String) -> Bool {
            let prefix = typeSelectBuffer.append(text)
            if selectNextProcess(matching: prefix) { return true }
            return selectNextProcess(matching: typeSelectBuffer.reset(to: text))
        }

        private func selectNextProcess(matching prefix: String) -> Bool {
            guard !visibleRows.isEmpty else { return false }
            let start = model.selection.flatMap { selection in visibleRows.firstIndex { $0.id == selection } } ?? -1
            for offset in 1...visibleRows.count {
                let index = (start + offset) % visibleRows.count
                guard let record = displayedProcesses()[visibleRows[index].id] else { continue }
                if record.name.lowercased().hasPrefix(prefix) {
                    model.selection = visibleRows[index].id
                    scrollRowToVisible(index)
                    invalidateAll()
                    return true
                }
            }
            return false
        }

        private func rowIndex(at point: NSPoint) -> Int? {
            let row = Int(point.y / Self.rowHeight)
            return row >= 0 ? row : nil
        }

        private func clickedDisclosure(at point: NSPoint, row: VisibleProcessRow) -> Bool {
            guard isExpandable(row.id) else { return false }
            let left = 5 + CGFloat(row.depth) * Self.indentationPerLevel
            return point.x >= left - 3 && point.x <= left + 12
        }

        private func metricColumn(at x: CGFloat) -> Column? {
            var origin: CGFloat = 0
            for column in metricColumns {
                let next = origin + width(for: column)
                if x >= origin && x < next { return column }
                origin = next
            }
            return nil
        }

        private func metricCellRect(for column: Column, rowIndex: Int) -> NSRect? {
            var x: CGFloat = 0
            for candidate in metricColumns {
                let columnWidth = width(for: candidate)
                if candidate == column {
                    return NSRect(
                        x: x,
                        y: CGFloat(rowIndex) * Self.rowHeight,
                        width: columnWidth,
                        height: Self.rowHeight
                    )
                }
                x += columnWidth
            }
            return nil
        }

        private func processTextRect(for row: VisibleProcessRow, rowIndex: Int) -> NSRect {
            let disclosureX = 5 + CGFloat(row.depth) * Self.indentationPerLevel
            let iconX = disclosureX + 13
            return NSRect(
                x: iconX + Self.iconSize + 5,
                y: CGFloat(rowIndex) * Self.rowHeight + 1,
                width: max(0, processContentWidth() - iconX - Self.iconSize - 9),
                height: Self.rowHeight - 2
            )
        }

        private func beginResizeIfNeeded(kind: ProcessListSurfaceKind, at point: NSPoint) -> Bool {
            switch kind {
            case .processHeader:
                guard abs(point.x - processPaneWidth) <= 5 else { return false }
                activeResize = ColumnResizeState(target: .process, startX: point.x, startWidth: processPaneWidth)
                return true
            case .metricsHeader:
                guard let (column, edgeX) = metricResizeHit(at: point.x) else { return false }
                activeResize = ColumnResizeState(target: .metric(column), startX: edgeX, startWidth: width(for: column))
                return true
            case .processRows, .metricsRows:
                return false
            }
        }

        private func beginColumnDragIfNeeded(at point: NSPoint) {
            guard let column = metricColumn(at: point.x) else { return }
            activeColumnDrag = ColumnDragState(column: column, startX: point.x, didMove: false)
        }

        private func autoFitDividerIfNeeded(kind: ProcessListSurfaceKind, at point: NSPoint) -> Bool {
            switch kind {
            case .processHeader:
                guard abs(point.x - processPaneWidth) <= 5 else { return false }
                autoFitProcessColumn()
                return true
            case .metricsHeader:
                guard let (column, _) = metricResizeHit(at: point.x) else { return false }
                autoFitMetricColumn(column)
                return true
            case .processRows, .metricsRows:
                return false
            }
        }

        private func autoFitProcessColumn() {
            var width = ceil((Column.name.title as NSString).size(withAttributes: boldTextAttributes).width) + 24
            let fontAttributes = regularTextAttributes
            for row in visibleRows {
                guard let record = snapshot.processes[row.id] else { continue }
                let textWidth = (record.name as NSString).size(withAttributes: fontAttributes).width
                let rowWidth = 5 + CGFloat(row.depth) * Self.indentationPerLevel + 13 + Self.iconSize + 5 + textWidth + 16
                width = max(width, ceil(rowWidth))
            }
            resizeProcessPane(to: max(Self.minProcessPaneWidth, width))
        }

        private func autoFitMetricColumn(_ column: Column) {
            var width = ceil((column.title as NSString).size(withAttributes: boldTextAttributes).width) + 18
            let attributes = column.isRightAligned ? numericTextAttributes : regularTextAttributes
            for row in visibleRows {
                guard let record = snapshot.processes[row.id] else { continue }
                let value = column.string(for: record)
                width = max(width, ceil((value as NSString).size(withAttributes: attributes).width) + 12)
            }
            metricColumnWidths[column] = max(Self.minMetricColumnWidth, width)
            persistMetricColumnWidth(column)
            updateCanvasFrames()
        }

        private func persistMetricColumnWidth(_ column: Column) {
            guard let width = metricColumnWidths[column] else { return }
            var widths = model.columnWidths
            widths[column.rawValue] = Double(width)
            model.columnWidths = widths
        }

        private func metricResizeHit(at x: CGFloat) -> (Column, CGFloat)? {
            var origin: CGFloat = 0
            for column in metricColumns {
                let next = origin + width(for: column)
                if abs(x - next) <= 5 { return (column, next) }
                origin = next
            }
            return nil
        }

        private func metricResizeRects() -> [NSRect] {
            var rects: [NSRect] = []
            var origin: CGFloat = 0
            for column in metricColumns {
                origin += width(for: column)
                rects.append(NSRect(x: origin - 4, y: 0, width: 8, height: Self.headerHeight))
            }
            return rects
        }

        private func metricColumnInsertionIndex(at x: CGFloat, excluding draggedColumn: Column) -> Int {
            let columns = metricColumns.filter { $0 != draggedColumn }
            var origin: CGFloat = 0
            for (index, column) in columns.enumerated() {
                let columnWidth = width(for: column)
                if x < origin + columnWidth / 2 { return index }
                origin += columnWidth
            }
            return columns.count
        }

        private func moveMetricColumn(_ column: Column, toMetricIndex index: Int) {
            var columns = metricColumns.filter { $0 != column }
            let target = max(0, min(index, columns.count))
            columns.insert(column, at: target)
            let reordered: [Column] = [.name] + columns
            guard reordered != currentColumns else { return }
            currentColumns = reordered
            model.columns = reordered
            updateCanvasFrames()
            invalidateAll()
        }

        private func sort(by column: Column?) {
            guard let column else { return }
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
            rebuildDisplayTree()
            rebuildRowsAfterSort()
        }

        private func cycleProcessColumnSort() {
            if sortColumn != .name {
                sortColumn = .name
                sortAscending = true
            } else if sortAscending {
                sortAscending = false
            } else {
                sortColumn = nil
                sortAscending = true
            }
            rebuildDisplayTree()
            rebuildRowsAfterSort()
        }

        private func rebuildRowsAfterSort() {
            if let selection = model.selection, sortColumn == nil {
                expandAncestors(of: selection)
            }
            rebuildVisibleRows()
            rebuildProcessWidthCache()
            rebuildUsageMaxima()
            updateCanvasFrames()
            scrollSelectionToVisible()
        }

        private func expandAncestors(of pid: ProcessID) {
            var ancestor = snapshot.processes[pid]?.parent
            var seen = Set<ProcessID>()
            while let current = ancestor, snapshot.processes[current] != nil, !seen.contains(current) {
                expanded.insert(current)
                seen.insert(current)
                ancestor = snapshot.processes[current]?.parent
            }
        }

        private func scrollSelectionToVisible() {
            guard let selection = model.selection,
                  let row = visibleRows.firstIndex(where: { $0.id == selection }) else { return }
            scrollRowToVisible(row)
        }

        private func drawUsageHeaderBackground(for column: Column, in rect: NSRect) {
            guard let base = usageBaseColor(for: column) else { return }
            let top = base.blended(withFraction: 0.72, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.35, of: .white) ?? base
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
        }

        private func drawUsageCellBackground(for column: Column, record: ProcessRecord, in rect: NSRect) {
            guard let base = usageBaseColor(for: column), let fraction = usageFraction(for: column, record: record), fraction > 0 else { return }
            let clamped = min(1, max(0, fraction))
            let fillWidth = max(2, floor(rect.width * clamped))
            let usageRect = NSRect(x: rect.maxX - fillWidth, y: rect.minY, width: fillWidth, height: rect.height)
            let alpha = 0.22 + 0.38 * clamped
            let top = base.withAlphaComponent(alpha * 0.58)
            let bottom = base.withAlphaComponent(alpha)
            NSGradient(starting: top, ending: bottom)?.draw(in: usageRect, angle: -90)
        }

        private func usageBaseColor(for column: Column) -> NSColor? {
            switch column {
            case .cpu:
                return NSColor(srgbRed: 60 / 255, green: 148 / 255, blue: 60 / 255, alpha: 1)
            case .privateBytes:
                return NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 0, alpha: 1)
            case .workingSet:
                return NSColor(srgbRed: 255 / 255, green: 128 / 255, blue: 64 / 255, alpha: 1)
            default:
                return nil
            }
        }

        private func usageFraction(for column: Column, record: ProcessRecord) -> CGFloat? {
            switch column {
            case .cpu:
                return CGFloat(record.cpuPercent / 100)
            case .privateBytes:
                guard maxVisiblePrivateBytes > 0 else { return nil }
                let value = record.physFootprint ?? record.residentSize
                return CGFloat(Double(value) / Double(maxVisiblePrivateBytes))
            case .workingSet:
                guard maxVisibleWorkingSet > 0 else { return nil }
                return CGFloat(Double(record.residentSize) / Double(maxVisibleWorkingSet))
            default:
                return nil
            }
        }

        private func plainMetricBackground(for column: Column) -> Bool {
            switch column {
            case .cpu, .privateBytes, .workingSet:
                return true
            default:
                return false
            }
        }

        func tooltipText(in kind: ProcessListSurfaceKind, at point: NSPoint) -> String? {
            guard kind == .processRows || kind == .metricsRows,
                  let rowIndex = rowIndex(at: point), visibleRows.indices.contains(rowIndex),
                  let record = snapshot.processes[visibleRows[rowIndex].id]
            else {
                return nil
            }
            if let cellTooltip = clippedCellTooltip(in: kind, at: point, rowIndex: rowIndex, record: record) {
                return cellTooltip
            }
            guard kind == .processRows else { return nil }
            // Plain lines (no labels/indent): name, description, company, and
            // version when available, followed by labelled Path and Command Line.
            var lines: [String] = [record.name]
            if let description = record.displayDescription, !description.isEmpty {
                lines.append(description)
            }
            if let company = record.companyName, !company.isEmpty {
                lines.append(company)
            }
            if let version = record.version, !version.isEmpty {
                lines.append(version)
            }
            let path = record.executablePath ?? ""
            lines.append("Path:\n    \(path.isEmpty ? "—" : path)")
            scheduleCommandLineLookup(for: record.id)
            if let commandLine = record.commandLine ?? commandLineCache[record.id], !commandLine.isEmpty {
                lines.append("Command Line:\n    \(commandLine)")
            }
            return lines.joined(separator: "\n")
        }

        private func clippedCellTooltip(in kind: ProcessListSurfaceKind, at point: NSPoint, rowIndex: Int, record: ProcessRecord) -> String? {
            switch kind {
            case .processRows:
                // Process rows always show the name/description/company/version
                // tooltip built by `tooltipText`, so no clipped-cell tooltip here.
                return nil
            case .metricsRows:
                guard let column = metricColumn(at: point.x),
                      let rect = metricCellRect(for: column, rowIndex: rowIndex)?.insetBy(dx: 4, dy: 1),
                      rect.contains(point) else { return nil }
                return clippedTooltipText(column.string(for: record), in: rect, rightAligned: column.isRightAligned)
            default:
                return nil
            }
        }

        private func clippedTooltipText(_ text: String, in rect: NSRect, rightAligned: Bool) -> String? {
            guard !text.isEmpty else { return nil }
            let font: NSFont = rightAligned
                ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
            return textWidth > rect.width + 0.5 ? text : nil
        }

        private func scheduleCommandLineLookup(for id: ProcessID) {
            guard commandLineCache[id] == nil, !commandLineInFlight.contains(id) else { return }
            commandLineInFlight.insert(id)
            let data = model.data
            Task { @MainActor in
                let commandLine = (try? await data.commandLine(of: id)) ?? ""
                if commandLine.isEmpty {
                    self.commandLineCache.removeValue(forKey: id)
                } else {
                    self.commandLineCache[id] = commandLine
                }
                self.commandLineInFlight.remove(id)
            }
        }

        private func isExpandable(_ pid: ProcessID) -> Bool {
            !(displayChildren[pid] ?? []).isEmpty
        }

        private func scrollRowToVisible(_ row: Int) {
            guard let metricsBodyScrollView else { return }
            let rowMinY = CGFloat(row) * Self.rowHeight
            let rowMaxY = rowMinY + Self.rowHeight
            var origin = metricsBodyScrollView.contentView.bounds.origin
            let visibleMinY = origin.y
            let visibleMaxY = origin.y + metricsBodyScrollView.contentView.bounds.height
            if rowMinY < visibleMinY {
                origin.y = rowMinY
            } else if rowMaxY > visibleMaxY {
                origin.y = rowMaxY - metricsBodyScrollView.contentView.bounds.height
            } else {
                return
            }
            metricsBodyScrollView.contentView.scroll(to: origin)
            metricsBodyScrollView.reflectScrolledClipView(metricsBodyScrollView.contentView)
        }

        func openPropertiesForSelection() {
            guard let pid = model.selection else { return }
            onCommand(.properties, pid)
        }

        private func clickedProcessID() -> ProcessID? {
            model.selection
        }

        @objc private func menuKill(_ sender: Any?) { emit(.kill) }
        @objc private func menuKillTree(_ sender: Any?) { emit(.killTree) }
        @objc private func menuSuspendResume(_ sender: Any?) { emit(.suspendResume) }
        @objc private func menuBringToFront(_ sender: Any?) { emit(.bringToFront) }
        @objc private func menuRestart(_ sender: Any?) { emit(.restart) }
        @objc private func menuSample(_ sender: Any?) { emit(.sample) }
        @objc private func menuSearchOnline(_ sender: Any?) { emit(.searchOnline) }
        @objc private func menuCheckVirusTotal(_ sender: Any?) { emit(.checkVirusTotal) }
        @objc private func menuProperties(_ sender: Any?) { emit(.properties) }
        @objc private func menuCopy(_ sender: Any?) { emit(.copy) }

        @objc private func menuSetNice(_ sender: Any?) {
            guard let item = sender as? NSMenuItem, let pid = clickedProcessID() else { return }
            onCommand(.setNice(Int32(item.tag)), pid)
        }

        private func emit(_ command: ProcessCommand) {
            guard let pid = clickedProcessID() else { return }
            onCommand(command, pid)
        }

        private func icon(for record: ProcessRecord) -> NSImage {
            if let iconPath = record.iconPath, !iconPath.isEmpty {
                if let cached = iconCache[iconPath] { return cached }
                let image = NSWorkspace.shared.icon(forFile: iconPath)
                image.size = NSSize(width: 15, height: 15)
                iconCache[iconPath] = image
                return image
            }
            if let bundleIdentifier = record.bundleIdentifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                let path = url.path
                if let cached = iconCache[path] { return cached }
                let image = NSWorkspace.shared.icon(forFile: path)
                image.size = NSSize(width: 15, height: 15)
                iconCache[path] = image
                return image
            }
            if let path = record.executablePath, !path.isEmpty {
                let iconPath = appBundlePath(containing: path) ?? path
                if let cached = iconCache[iconPath] { return cached }
                let image = NSWorkspace.shared.icon(forFile: iconPath)
                image.size = NSSize(width: 15, height: 15)
                iconCache[iconPath] = image
                return image
            }
            return NSWorkspace.shared.icon(for: .unixExecutable)
        }

        private func appBundlePath(containing executablePath: String) -> String? {
            var url = URL(fileURLWithPath: executablePath)
            while !url.path.isEmpty && url.path != "/" {
                if ["app", "xpc", "appex"].contains(url.pathExtension) { return url.path }
                url.deleteLastPathComponent()
            }
            return nil
        }

        private func rowColor(for pid: ProcessID, dark: Bool) -> NSColor? {
            guard let record = displayedProcesses()[pid] else { return nil }
            var flags = record.flags
            switch processHighlights[pid]?.kind {
            case .new: flags.insert(.newProcess)
            case .deleted: flags.insert(.deadProcess)
            case nil: break
            }
            guard let rgba = ProcessColorRule.background(for: flags, rules: currentRules, darkMode: dark) else { return nil }
            return NSColor(srgbRed: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
        }

        private func isDarkMode(_ view: NSView) -> Bool {
            view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
}

private struct VisibleProcessRow {
    let id: ProcessID
    let depth: Int
}

private struct ColumnResizeState {
    let target: ColumnResizeTarget
    let startX: CGFloat
    let startWidth: CGFloat
}

private struct ColumnDragState {
    let column: Column
    let startX: CGFloat
    var didMove: Bool
}

private enum ColumnResizeTarget {
    case process
    case metric(Column)
}

enum ProcessListSurfaceKind {
    case processHeader
    case metricsHeader
    case processRows
    case metricsRows
}

enum ProcessScrollSource {
    case processRows
    case metricsRows
}

@MainActor
final class ProcessListContainerView: NSView {
    let processHeaderView = ProcessListSurfaceView(kind: .processHeader)
    let metricsHeaderView = ProcessListSurfaceView(kind: .metricsHeader)
    let processRowsView = ProcessListSurfaceView(kind: .processRows)
    let metricsRowsView = ProcessListSurfaceView(kind: .metricsRows)
    let processBodyScrollView = ProcessPaneScrollView(frame: .zero)
    let metricsHeaderScrollView = NSScrollView(frame: .zero)
    let metricsBodyScrollView = ProcessPaneScrollView(frame: .zero)

    private let divider = ProcessDividerView(frame: .zero)
    private var didConfigure = false
    private var processHeaderWidthConstraint: NSLayoutConstraint?
    private var processBodyWidthConstraint: NSLayoutConstraint?

    func configure(coordinator: ProcessOutlineView.Coordinator, processPaneWidth: CGFloat) {
        guard !didConfigure else { return }
        didConfigure = true

        for view in [processHeaderView, metricsHeaderView, processRowsView, metricsRowsView] {
            view.coordinator = coordinator
        }
        processBodyScrollView.coordinator = coordinator
        metricsBodyScrollView.coordinator = coordinator
        divider.coordinator = coordinator
        configureScrollView(processBodyScrollView, horizontal: true, vertical: false, scrollers: true)
        configureScrollView(metricsHeaderScrollView, horizontal: true, vertical: false, scrollers: false)
        configureScrollView(metricsBodyScrollView, horizontal: true, vertical: true, scrollers: true)
        processBodyScrollView.documentView = processRowsView
        metricsHeaderScrollView.documentView = metricsHeaderView
        metricsBodyScrollView.documentView = metricsRowsView

        processHeaderView.translatesAutoresizingMaskIntoConstraints = false
        metricsHeaderScrollView.translatesAutoresizingMaskIntoConstraints = false
        processBodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        metricsBodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(processHeaderView)
        addSubview(metricsHeaderScrollView)
        addSubview(processBodyScrollView)
        addSubview(divider)
        addSubview(metricsBodyScrollView)

        let headerWidth = processHeaderView.widthAnchor.constraint(equalToConstant: processPaneWidth)
        let bodyWidth = processBodyScrollView.widthAnchor.constraint(equalToConstant: processPaneWidth)
        processHeaderWidthConstraint = headerWidth
        processBodyWidthConstraint = bodyWidth

        NSLayoutConstraint.activate([
            processHeaderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            processHeaderView.topAnchor.constraint(equalTo: topAnchor),
            headerWidth,
            processHeaderView.heightAnchor.constraint(equalToConstant: ProcessOutlineView.Coordinator.headerHeight),

            processBodyScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            processBodyScrollView.topAnchor.constraint(equalTo: processHeaderView.bottomAnchor),
            processBodyScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyWidth,

            divider.leadingAnchor.constraint(equalTo: processHeaderView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 5),

            metricsHeaderScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            metricsHeaderScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metricsHeaderScrollView.topAnchor.constraint(equalTo: topAnchor),
            metricsHeaderScrollView.heightAnchor.constraint(equalToConstant: ProcessOutlineView.Coordinator.headerHeight),

            metricsBodyScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            metricsBodyScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metricsBodyScrollView.topAnchor.constraint(equalTo: metricsHeaderScrollView.bottomAnchor),
            metricsBodyScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setProcessPaneWidth(_ width: CGFloat) {
        processHeaderWidthConstraint?.constant = width
        processBodyWidthConstraint?.constant = width
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        processBodyScrollView.coordinator?.updateCanvasFrames()
    }

    private func configureScrollView(_ scrollView: NSScrollView, horizontal: Bool, vertical: Bool, scrollers: Bool) {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasHorizontalScroller = horizontal && scrollers
        scrollView.hasVerticalScroller = vertical && scrollers
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
    }
}

@MainActor
final class ProcessPaneScrollView: NSScrollView {
    let syncClipView = ProcessSyncClipView(frame: .zero)
    weak var coordinator: ProcessOutlineView.Coordinator?
    var isProcessPane = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = syncClipView
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        contentView = syncClipView
    }

    override func layout() {
        super.layout()
        coordinator?.updateCanvasFrames()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === syncClipView, let source = syncClipView.source else { return }
        coordinator?.syncScroll(from: source)
    }

    override func scrollWheel(with event: NSEvent) {
        if isProcessPane && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            coordinator?.forwardProcessWheelToMetrics(event)
            return
        }
        super.scrollWheel(with: event)
        if let source = syncClipView.source {
            coordinator?.syncScroll(from: source)
        }
    }
}

@MainActor
final class ProcessSyncClipView: NSClipView {
    weak var coordinator: ProcessOutlineView.Coordinator?
    var source: ProcessScrollSource?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        guard let source else { return }
        coordinator?.syncScroll(from: source)
    }
}

@MainActor
final class ProcessDividerView: NSView {
    weak var coordinator: ProcessOutlineView.Coordinator?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        coordinator?.resizeProcessPane(to: point.x - bounds.width / 2)
    }
}

@MainActor
final class ProcessListSurfaceView: NSView {
    let kind: ProcessListSurfaceKind
    weak var coordinator: ProcessOutlineView.Coordinator?
    private var hoverTrackingArea: NSTrackingArea?
    private let instantTooltip = ProcessInstantTooltip()

    init(kind: ProcessListSurfaceKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Disable AppKit's asynchronous "responsive scrolling" overlay. The process
    // list is custom-drawn across two vertically-synced panes; the async overlay
    // can slide a cached tile and redraw only the exposed edge out of step with
    // the sibling pane's mirror, which momentarily compresses/overlaps rows
    // during scrolling. Synchronous scrolling keeps both panes in lockstep.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        coordinator?.draw(surface: self, dirtyRect: dirtyRect)
    }

    override func resetCursorRects() {
        coordinator?.updateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseDown(in: kind, at: point, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseDragged(in: kind, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseUp(in: kind, at: point)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateTooltip(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateTooltip(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        instantTooltip.hide()
    }

    private func updateTooltip(for event: NSEvent) {
        guard kind == .processRows || kind == .metricsRows else {
            instantTooltip.hide()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let text = coordinator?.tooltipText(in: kind, at: point), !text.isEmpty else {
            instantTooltip.hide()
            return
        }
        instantTooltip.show(text: text, near: event, from: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let menu = coordinator?.handleRightMouseDown(in: kind, at: point) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            coordinator?.openPropertiesForSelection()
        case 125:
            coordinator?.moveSelection(delta: 1)
        case 126:
            coordinator?.moveSelection(delta: -1)
        default:
            if let text = event.typeSelectText, coordinator?.handleTypeSelect(text) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ProcessInstantTooltip {
    private let maxWidth: CGFloat = 720
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 7
    private let valueIndent: CGFloat = 24
    private let label = NSTextField(labelWithString: "")
    private let container = NSView(frame: .zero)
    private var window: NSWindow?
    private weak var sourceView: NSView?
    private var visibilityTimer: Timer?

    init() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        container.addSubview(label)
    }

    func show(text: String, near event: NSEvent, from view: NSView) {
        guard let sourceWindow = view.window else { return }
        sourceView = view
        startVisibilityTimer()
        let attributedText = attributedTooltip(for: text)
        let contentWidth = tooltipContentWidth(for: text)
        let size = tooltipSize(for: attributedText, contentWidth: contentWidth)
        label.attributedStringValue = attributedText
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: contentWidth,
            height: size.height - verticalPadding * 2
        )
        container.frame = NSRect(origin: .zero, size: size)

        let tooltipWindow = window ?? makeWindow(size: size)
        window = tooltipWindow
        tooltipWindow.setContentSize(size)
        let screenPoint = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        tooltipWindow.setFrameOrigin(clampedOrigin(near: screenPoint, size: size, screen: sourceWindow.screen ?? NSScreen.main))
        tooltipWindow.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        sourceView = nil
    }

    private func startVisibilityTimer() {
        guard visibilityTimer == nil else { return }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfMouseLeftSource()
            }
        }
    }

    private func hideIfMouseLeftSource() {
        guard let sourceView, let sourceWindow = sourceView.window, sourceWindow.isVisible else {
            hide()
            return
        }
        let windowPoint = sourceWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = sourceView.convert(windowPoint, from: nil)
        if !sourceView.bounds.contains(localPoint) {
            hide()
        }
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let tooltipWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        tooltipWindow.contentView = container
        tooltipWindow.backgroundColor = .clear
        tooltipWindow.isOpaque = false
        tooltipWindow.hasShadow = true
        tooltipWindow.ignoresMouseEvents = true
        tooltipWindow.level = .floating
        return tooltipWindow
    }

    private func attributedTooltip(for text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let isValue = line.hasPrefix("    ")
            let displayLine = isValue ? String(line.drop { $0 == " " }) : line
            let paragraph = NSMutableParagraphStyle()
            if isValue {
                paragraph.lineBreakMode = .byCharWrapping
                paragraph.firstLineHeadIndent = valueIndent
                paragraph.headIndent = valueIndent
            } else {
                paragraph.lineBreakMode = .byClipping
            }
            result.append(NSAttributedString(
                string: displayLine,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }

    private func tooltipContentWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let maxContentWidth = maxWidth - horizontalPadding * 2
        let minimumLabelWidth = max(labelWidth("Path:"), labelWidth("Command Line:"))
        var width: CGFloat = minimumLabelWidth
        for line in text.components(separatedBy: "\n") {
            let isValue = line.hasPrefix("    ")
            let displayLine = isValue ? String(line.drop { $0 == " " }) : line
            let textWidth = ceil((displayLine as NSString).size(withAttributes: attributes).width) + 4
            width = max(width, textWidth + (isValue ? valueIndent : 0))
        }
        return min(maxContentWidth, max(1, width))
    }

    private func labelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width)
    }

    private func tooltipSize(for text: NSAttributedString, contentWidth: CGFloat) -> NSSize {
        let bounds = usedRect(for: text, contentWidth: contentWidth)
        return NSSize(
            width: contentWidth + horizontalPadding * 2,
            height: ceil(bounds.height) + verticalPadding * 2
        )
    }

    private func usedRect(for text: NSAttributedString, contentWidth: CGFloat) -> NSRect {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        container.lineBreakMode = .byWordWrapping
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container)
    }

    private func clampedOrigin(near point: NSPoint, size: NSSize, screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 6
        var x = point.x + 14
        var y = point.y - size.height - 16
        if y < visible.minY + margin {
            y = point.y + 16
        }
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }
}