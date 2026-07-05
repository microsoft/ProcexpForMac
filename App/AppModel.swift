//
//  AppModel.swift
//  Central observable app state. Owns the data providers and the latest
//  process snapshot, and drives the refresh loop.
//

import Foundation
import Observation
import AppKit
import ApplicationServices
import ProcexpModel
import ProcexpSampling
import ProcexpSigning
import ProcexpNetwork
import ProcexpGraphs
import ProcexpAutostart
import ProcexpActions
import ProcexpPrivileged

struct ColumnSet: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var columns: [Column]
    var processColumnWidth: Double
    var columnWidths: [String: Double]

    var id: String { name }
}

struct TargetWindowPickerAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var offersAccessibilitySettings: Bool = false
}

struct ProcessActionAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum SystemInfoTab: Hashable {
    case summary
    case cpu
    case memory
    case io
    case network
    case gpu
}

@MainActor
@Observable
final class AppModel {
    static let defaultProcessColumnWidth: Double = 430

    // Latest sampled state.
    var snapshot: ProcessSnapshot = .empty
    var selection: ProcessID?

    // View configuration. `didSet` observers persist changes (W11) once the
    // stored settings have finished loading at launch.
    var refreshInterval: TimeInterval = 1.0 { didSet { persistSettings() } }
    var columns: [Column] = Column.defaultColumns {
        didSet {
            guard !normalizingColumns else { return }
            let normalized = Self.normalizedColumns(columns)
            if normalized != columns {
                normalizingColumns = true
                columns = normalized
                normalizingColumns = false
            }
            persistSettings()
        }
    }
    var processColumnWidth: Double = AppModel.defaultProcessColumnWidth { didSet { persistSettings() } }
    var columnWidths: [String: Double] = [:] { didSet { persistSettings() } }
    var columnSets: [ColumnSet] = [] { didSet { persistSettings() } }
    var moduleColumns: [ModuleColumn] = ModuleColumn.defaultColumns { didSet { persistSettings() } }
    var handleColumns: [HandleColumn] = HandleColumn.defaultColumns { didSet { persistSettings() } }
    var threadColumns: [ThreadColumn] = ThreadColumn.defaultColumns { didSet { persistSettings() } }
    var colorRules: [ProcessColorRule] = ProcessColorRule.defaults { didSet { persistSettings() } }

    // W11 preference toggles.
    var confirmBeforeKill: Bool = true { didSet { persistSettings() } }
    var verifySignatures: Bool = true { didSet { persistSettings() } }
    var differenceHighlightDuration: TimeInterval = 1.0 { didSet { persistSettings() } }

    /// Gate so restoring persisted settings at launch doesn't immediately
    /// re-save them (and so `init` assignments are never persisted early).
    private var settingsLoaded = false
    private var normalizingColumns = false

    // W5 lower-pane view state (mapped images vs. file descriptors).
    var showLowerPane: Bool = true
    var lowerPaneMode: LowerPaneMode = .modules
    var systemInfoTab: SystemInfoTab = .summary

    // R1 — show the process hierarchy (tree) vs. a flat list of all processes
    // (Procexp "View ▸ Show Process Tree", ⌥T).
    var showProcessTree: Bool = true
    var processTreeSortResetToken: Int = 0

    func showProcessTreeView() {
        showProcessTree = true
        processTreeSortResetToken += 1
    }

    // R1 — user-adjustable widths (points) of the three toolbar mini history
    // graphs (CPU, Memory, I/O). Each graph has a drag handle on its trailing
    // edge that writes back into this array.
    var graphWidths: [Double] = [64, 64, 64]

    // R1 — shared action coordinator (kill/suspend/… + confirmation dialogs) so
    // both the toolbar and the native menu bar drive the same flow.
    let actionCoordinator = ActionCoordinator()

    // R1 — UI intents raised by menu commands and observed by the main window.
    /// Presents the "Run…" launcher sheet (File ▸ Run…, ⌘R).
    var showRunSheet: Bool = false
    /// Presents View ▸ Select Columns….
    var showSelectColumnsSheet: Bool = false
    /// Presents View ▸ Save Column Set….
    var showSaveColumnSetSheet: Bool = false
    /// Presents View ▸ Organize Column Sets….
    var showOrganizeColumnSetsSheet: Bool = false
    /// Bumped to request focus of the filter field (Find ▸ Filter Processes, ⇧⌘F).
    var focusSearchToken: Int = 0
    /// Bumped to request saving the process list (File ▸ Save, ⌘S).
    var saveRequestToken: Int = 0

    // Target-window picker state. The toolbar starts a one-click global pick;
    // success writes `selection`, so the existing process-list selection path
    // remains the only owner of row highlighting and lower-pane follow mode.
    var targetWindowPickerActive: Bool = false
    var targetWindowPickerAlert: TargetWindowPickerAlert?
    var processActionAlert: ProcessActionAlert?
    private var targetWindowGlobalMonitor: Any?
    private var targetWindowLocalMonitor: Any?
    private var targetWindowCursorPushed = false

    // W10 — show the live CPU-history icon in the macOS menu bar.
    var showMenuBarGraph: Bool = true

    // R1 — sampling can be paused (Procexp "Update Speed ▸ Paused"). While
    // paused the snapshot stream is stopped; toggling off resumes it.
    var paused: Bool = false

    // R1 — keep the main window above others (Options ▸ Always On Top).
    var alwaysOnTop: Bool = false { didSet { applyAlwaysOnTop() } }

    // R1 — window appearance (Options ▸ Theme ▸ Light/Dark/System).
    var theme: AppTheme = .system { didSet { applyTheme() } }

    // System history rings for graphs (newest last).
    var systemHistoryTimestamps = HistoryRing<Date>(capacity: 120)
    var cpuHistory = HistoryRing<Double>(capacity: 120)
    var memoryHistory = HistoryRing<Double>(capacity: 120)

    // R1 — combined disk + network I/O throughput (bytes/sec) for the toolbar
    // mini I/O graph.
    var ioHistory = HistoryRing<Double>(capacity: 120)

    // W4 System Information window — additional live-history rings, all
    // capacity ~120 so they scroll at the same rate as CPU/memory.
    /// Physical memory used, as a percentage (0…100) — mirrors `memoryHistory`
    /// but kept separate for clarity in the System Information window.
    var swapHistory = HistoryRing<Double>(capacity: 120)          // bytes
    var diskHistory = HistoryRing<Double>(capacity: 120)          // bytes/sec
    var networkHistory = HistoryRing<Double>(capacity: 120)       // bytes/sec
    var gpuHistory = HistoryRing<Double>(capacity: 120)           // 0…100
    /// One ring per logical core; grown lazily to match `perCoreCPUPercent`.
    var perCoreHistory: [HistoryRing<Double>] = []

    // R5 — per-sample "top consumer" rings, index-aligned with the numeric
    // rings above (same 120 capacity, appended on the same tick). These let the
    // System Information graphs show, on hover, which process dominated a given
    // resource at that moment in time (like Procexp's graph tooltips).
    var cpuTopHistory = HistoryRing<TopConsumer>(capacity: 120)      // % CPU
    var memoryTopHistory = HistoryRing<TopConsumer>(capacity: 120)   // bytes (footprint)
    var ioTopHistory = HistoryRing<TopConsumer>(capacity: 120)       // bytes (disk read+write)
    var networkTopHistory = HistoryRing<TopConsumer>(capacity: 120)  // bytes/sec
    var gpuTopHistory = HistoryRing<TopConsumer>(capacity: 120)      // % GPU

    // Providers (protocol-typed so the UI never depends on concretes).
    private(set) var data: any ProcessDataProviding
    let signing: any SigningProviding
    let network: any NetworkProviding
    let system: any SystemStatsProviding

    /// W2 — the privileged root-helper provider, non-nil only when the helper
    /// is installed and reachable. When present it becomes the primary `data`
    /// provider (accurate per-thread CPU, cross-user detail) and is injected
    /// into `actions` so control operations can escalate.
    private(set) var privileged: PrivilegedDataProvider?

    /// The always-available unprivileged provider, kept for fallback.
    private let libproc: LibprocDataProvider
    private let gpuStats = GPUStatsProvider()

    /// W8 process-control command layer. Carries the privileged helper (when
    /// installed) so actions on other users' processes can escalate.
    private(set) var actions: ProcessActions
    let autostart: any AutostartProviding

    private var streamTask: Task<Void, Never>?

    // MARK: - Signature enrichment (fix #11)
    //
    // Verified-signer text is computed asynchronously (Security framework) and
    // merged into each published snapshot, so the "Verified Signer" column
    // fills in progressively instead of blocking sampling. Results are static
    // per executable path → cached permanently for the session.
    private var signatureCache: [String: SignatureInfo] = [:]
    private var signatureInFlight: Set<String> = []
    private let maxConcurrentSignatureLookups = 8
    private let maxNewSignatureLookupsPerRefresh = 12

    private var commandLineCache: [ProcessID: String] = [:]
    private var commandLineInFlight: Set<ProcessID> = []
    private let maxConcurrentCommandLineLookups = 16
    private let maxNewCommandLineLookupsPerRefresh = 32

    private var autostartCache: [String: String] = [:]
    private var autostartInFlight: Set<String> = []
    private let maxConcurrentAutostartLookups = 8
    private let maxNewAutostartLookupsPerRefresh = 32

    init() {
        let libproc = LibprocDataProvider()
        self.libproc = libproc
        self.signing = CodeSignProvider()
        self.network = NetworkProvider()
        self.system = SystemStatsProvider()
        self.autostart = AutostartProvider()

        // W2 — adopt the privileged path if the root helper is already
        // installed; otherwise run fully unprivileged (current behavior).
        if PrivilegedDataProvider.isHelperInstalled() {
            let priv = PrivilegedDataProvider()
            self.privileged = priv
            self.data = priv
            self.actions = ProcessActions(privileged: priv)
        } else {
            self.privileged = nil
            self.data = libproc
            self.actions = ProcessActions(privileged: nil)
        }

        // W11 — restore persisted preferences, then start tracking changes.
        SettingsStore.load(into: self)
        settingsLoaded = true
    }

    /// W2 — attempt to register the privileged root helper via `SMAppService`.
    /// On success, switch the app onto the privileged provider/actions and
    /// restart sampling. Returns a user-facing result.
    ///
    /// Under the current ad-hoc ("Sign to Run Locally") signature this reports
    /// a clean failure — registering a launchd daemon requires Developer-ID
    /// signing + embedding (W13). It never crashes.
    func installPrivilegedHelper() async -> (ok: Bool, message: String) {
        do {
            try await PrivilegedDataProvider.installHelper()
        } catch {
            return (false, """
            The privileged helper could not be registered.

            This is expected until the app is Developer-ID signed and the helper \
            is embedded under Contents/Library/LaunchDaemons (workstream W13). \
            Everything continues to work in the unprivileged mode.
            """)
        }

        guard PrivilegedDataProvider.isHelperInstalled() else {
            return (false, """
            The helper was registered but is not yet enabled. Approve it in \
            System Settings ▸ General ▸ Login Items & Extensions, then relaunch.
            """)
        }

        // Adopt the privileged path.
        let priv = PrivilegedDataProvider()
        self.privileged = priv
        self.data = priv
        self.actions = ProcessActions(privileged: priv)
        await start()
        return (true, "The privileged helper is installed and active. Accurate per-thread CPU and cross-user detail are now available.")
    }


    /// Persist the current settings whenever an observed value changes. No-op
    /// until the initial load has completed.
    private func persistSettings() {
        guard settingsLoaded else { return }
        SettingsStore.save(from: self)
    }

    static func normalizedColumns(_ columns: [Column]) -> [Column] {
        var seen = Set(Column.pinnedOnMac)
        var normalized = Column.pinnedOnMac
        for column in columns where !seen.contains(column) && column.isSupportedOnMac {
            seen.insert(column)
            normalized.append(column)
        }
        return normalized
    }

    static func sanitizedColumnWidths(_ widths: [String: Double]) -> [String: Double] {
        widths.filter { raw, width in
            guard let column = Column(rawValue: raw), column != .name else { return false }
            return column.isSupportedOnMac && width > 0 && width.isFinite
        }
    }

    static func normalizedColumnSets(_ sets: [ColumnSet]) -> [ColumnSet] {
        var usedNames = Set<String>()
        var normalized: [ColumnSet] = []
        for set in sets {
            let name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !usedNames.contains(key) else { continue }
            usedNames.insert(key)
            normalized.append(ColumnSet(
                name: name,
                columns: normalizedColumns(set.columns),
                processColumnWidth: set.processColumnWidth > 0 && set.processColumnWidth.isFinite
                    ? set.processColumnWidth
                    : defaultProcessColumnWidth,
                columnWidths: sanitizedColumnWidths(set.columnWidths)
            ))
        }
        return normalized
    }

    static func normalizedModuleColumns(_ columns: [ModuleColumn]) -> [ModuleColumn] {
        normalizedLowerPaneColumns(columns, defaultColumns: ModuleColumn.defaultColumns)
    }

    static func normalizedHandleColumns(_ columns: [HandleColumn]) -> [HandleColumn] {
        normalizedLowerPaneColumns(columns, defaultColumns: HandleColumn.defaultColumns)
    }

    static func normalizedThreadColumns(_ columns: [ThreadColumn]) -> [ThreadColumn] {
        normalizedLowerPaneColumns(columns, defaultColumns: ThreadColumn.defaultColumns)
    }

    private static func normalizedLowerPaneColumns<C: LowerPaneColumn>(_ columns: [C], defaultColumns: [C]) -> [C] {
        var seen = Set(C.requiredColumns)
        var normalized = C.requiredColumns
        for column in columns where seen.insert(column).inserted {
            normalized.append(column)
        }
        return normalized.isEmpty ? defaultColumns : normalized
    }

    func applyColumnSet(_ set: ColumnSet) {
        guard let normalized = Self.normalizedColumnSets([set]).first else { return }
        columns = normalized.columns
        processColumnWidth = normalized.processColumnWidth
        columnWidths = normalized.columnWidths
    }

    @discardableResult
    func saveCurrentColumnSet(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let visibleColumns = Self.normalizedColumns(columns)
        let visibleMetrics = Set(visibleColumns.filter { $0 != .name }.map(\.rawValue))
        let widths = Self.sanitizedColumnWidths(columnWidths)
            .filter { visibleMetrics.contains($0.key) }
        let set = ColumnSet(
            name: trimmed,
            columns: visibleColumns,
            processColumnWidth: processColumnWidth,
            columnWidths: widths
        )
        if let index = columnSets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            columnSets[index] = set
        } else {
            columnSets.append(set)
        }
        columnSets = Self.normalizedColumnSets(columnSets)
        return true
    }

    func deleteColumnSet(_ set: ColumnSet) {
        columnSets.removeAll { $0.name.localizedCaseInsensitiveCompare(set.name) == .orderedSame }
    }

    func hasColumnSet(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return columnSets.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func defaultColumnSetName() -> String {
        var index = columnSets.count + 1
        while hasColumnSet(named: "Column Set \(index)") {
            index += 1
        }
        return "Column Set \(index)"
    }

    // MARK: - Process / image actions

    func searchOnlineForSelectedProcess() {
        guard let pid = selection else { return }
        searchOnline(forProcess: pid)
    }

    func searchOnline(forProcess pid: ProcessID) {
        guard let record = snapshot.info(pid) else {
            processActionAlert = ProcessActionAlert(
                title: "Process Not Found",
                message: "The selected process is no longer present in the current snapshot."
            )
            return
        }
        let query = searchQuery(name: record.name, path: record.executablePath, fallback: "process")
        openSearchOnline(query: query)
    }

    func searchOnlineForImage(name: String, path: String) {
        let query = searchQuery(name: name, path: path, fallback: "image")
        openSearchOnline(query: query)
    }

    func checkVirusTotalForSelectedProcess() async {
        guard let pid = selection else { return }
        await checkVirusTotal(forProcess: pid)
    }

    func checkVirusTotal(forProcess pid: ProcessID) async {
        guard let record = snapshot.info(pid) else {
            processActionAlert = ProcessActionAlert(
                title: "Process Not Found",
                message: "The selected process is no longer present in the current snapshot."
            )
            return
        }
        guard let path = record.executablePath, !path.isEmpty else {
            processActionAlert = ProcessActionAlert(
                title: "VirusTotal Unavailable",
                message: "No executable path is available for \(record.name)."
            )
            return
        }
        await checkVirusTotal(displayName: record.name, path: path, signature: record.signing)
    }

    func checkVirusTotalForImage(name: String, path: String, signature: SignatureInfo? = nil) async {
        guard !path.isEmpty else {
            processActionAlert = ProcessActionAlert(
                title: "VirusTotal Unavailable",
                message: "No image path is available for \(name)."
            )
            return
        }
        await checkVirusTotal(displayName: name, path: path, signature: signature)
    }

    private func searchQuery(name: String, path: String?, fallback: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && !trimmedPath.isEmpty {
            return "\(trimmedName) \(trimmedPath)"
        }
        if !trimmedName.isEmpty { return "\(trimmedName) \(fallback)" }
        if !trimmedPath.isEmpty { return trimmedPath }
        return fallback
    }

    private func openSearchOnline(query: String) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "duckduckgo.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            processActionAlert = ProcessActionAlert(
                title: "Search Online Unavailable",
                message: "Could not build a search URL for \"\(query)\"."
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func checkVirusTotal(displayName: String, path: String, signature existingSignature: SignatureInfo?) async {
        let signature: SignatureInfo
        if let existingSignature, let sha = existingSignature.sha256, !sha.isEmpty {
            signature = existingSignature
        } else {
            signature = await signing.signature(forPath: path)
        }

        guard let sha = signature.sha256, !sha.isEmpty else {
            processActionAlert = ProcessActionAlert(
                title: "VirusTotal Unavailable",
                message: "No SHA-256 hash is available for \(displayName). The file may no longer exist or may not be readable."
            )
            return
        }

        do {
            if let result = try await signing.virusTotal(sha256: sha) {
                processActionAlert = ProcessActionAlert(
                    title: "VirusTotal Result",
                    message: virusTotalMessage(displayName: displayName, result: result)
                )
            } else {
                processActionAlert = ProcessActionAlert(
                    title: "VirusTotal Result",
                    message: "No VirusTotal report is available for \(displayName). Configure a VirusTotal API key in the login Keychain, or the file may be unknown to VirusTotal."
                )
            }
        } catch {
            processActionAlert = ProcessActionAlert(
                title: "VirusTotal Lookup Failed",
                message: "VirusTotal lookup failed for \(displayName): \(describe(error))"
            )
        }
    }

    private func virusTotalMessage(displayName: String, result: VirusTotalResult) -> String {
        var message = "\(displayName): \(result.positives)/\(result.total) engines flagged this file."
        if let permalink = result.permalink, !permalink.isEmpty {
            message += "\n\n\(permalink)"
        }
        return message
    }

    private func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }

    /// Begin (or restart) the snapshot stream at the current refresh interval.
    func start() async {
        streamTask?.cancel()
        // R1 — honour the paused state: stop streaming entirely.
        guard !paused else {
            streamTask = nil
            return
        }
        let provider: any ProcessDataProviding = data
        let interval = refreshInterval
        let system = self.system
        streamTask = Task { @MainActor in
            for await snap in provider.snapshots(interval: interval) {
                let enriched = self.enrichWithSignatures(self.enrichWithAutostart(self.enrichWithCommandLines(snap)))
                self.snapshot = enriched
                let stats = await system.stats()
                self.systemHistoryTimestamps.append(Date())
                self.cpuHistory.append(stats.cpuTotalPercent)
                let memPct = stats.memoryTotal > 0
                    ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
                    : 0
                self.memoryHistory.append(memPct)

                // W4 — record the remaining System Information series.
                self.swapHistory.append(Double(stats.swapUsed))
                self.diskHistory.append(Double(stats.diskBytesPerSec))
                self.networkHistory.append(Double(stats.networkBytesPerSec))
                let gpuPercent = await self.gpuStats.systemGPUPercent()
                self.gpuHistory.append(gpuPercent ?? 0)

                // R5 — record the top consumer for each resource this tick.
                self.appendTopConsumers(for: snap)

                // R1 — combined I/O throughput for the toolbar mini graph.
                self.ioHistory.append(Double(stats.diskBytesPerSec) + Double(stats.networkBytesPerSec))

                // Grow the per-core rings to match the current core count,
                // then append each core's utilisation.
                let cores = stats.perCoreCPUPercent
                if self.perCoreHistory.count != cores.count {
                    self.perCoreHistory = (0..<cores.count).map { index in
                        index < self.perCoreHistory.count
                            ? self.perCoreHistory[index]
                            : HistoryRing<Double>(capacity: 120)
                    }
                }
                for (index, value) in cores.enumerated() {
                    self.perCoreHistory[index].append(value)
                }

                if Task.isCancelled { break }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - R1 controls

    /// Toggle the paused state (Procexp "Update Speed ▸ Paused"). Restarts or
    /// stops the snapshot stream accordingly.
    func togglePause() {
        paused.toggle()
        Task { await start() }
    }

    /// Take a single snapshot immediately (Procexp "Refresh Now", F5) without
    /// disturbing the running stream. Also updates the history rings so the
    /// graphs advance a step.
    func forceRefresh() async {
        let provider: any ProcessDataProviding = data
        let snap = await provider.snapshot()
        self.snapshot = self.enrichWithSignatures(self.enrichWithAutostart(self.enrichWithCommandLines(snap)))
        let stats = await system.stats()
        systemHistoryTimestamps.append(Date())
        cpuHistory.append(stats.cpuTotalPercent)
        let memPct = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0
        memoryHistory.append(memPct)
        let gpuPercent = await gpuStats.systemGPUPercent()
        gpuHistory.append(gpuPercent ?? 0)
        ioHistory.append(Double(stats.diskBytesPerSec) + Double(stats.networkBytesPerSec))
    }

    // MARK: - Target-window picker

    func toggleTargetWindowPicker() {
        if targetWindowPickerActive {
            cancelTargetWindowPicker()
        } else {
            beginTargetWindowPicker()
        }
    }

    func beginTargetWindowPicker() {
        clearTargetWindowPickerMonitors()
        targetWindowPickerAlert = nil
        targetWindowPickerActive = true
        if !targetWindowCursorPushed {
            NSCursor.crosshair.push()
            targetWindowCursorPushed = true
        }

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if event.type == .rightMouseDown {
                    self.cancelTargetWindowPicker()
                } else {
                    await self.completeTargetWindowPick(at: point)
                }
            }
        }

        guard let globalMonitor else {
            finishTargetWindowPicker()
            targetWindowPickerAlert = TargetWindowPickerAlert(
                title: "Window Picker Unavailable",
                message: "macOS did not allow ProcexpMac to monitor the next mouse click. Grant Accessibility access in System Settings > Privacy & Security > Accessibility, then try again.",
                offersAccessibilitySettings: true
            )
            return
        }
        targetWindowGlobalMonitor = globalMonitor

        targetWindowLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode != 53 {
                return event
            }
            Task { @MainActor in self?.cancelTargetWindowPicker() }
            return nil
        }
    }

    func cancelTargetWindowPicker() {
        finishTargetWindowPicker()
    }

    func openAccessibilitySettingsForTargetPicker() {
        targetWindowPickerAlert = nil
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func completeTargetWindowPick(at appKitPoint: NSPoint) async {
        finishTargetWindowPicker()
        guard let ownerPID = Self.windowOwnerPID(at: appKitPoint) ?? Self.accessibilityOwnerPID(at: appKitPoint) else {
            targetWindowPickerAlert = Self.noWindowPIDAlert()
            return
        }

        if selectProcess(ownerPID: ownerPID) { return }
        await forceRefresh()
        if selectProcess(ownerPID: ownerPID) { return }

        targetWindowPickerAlert = TargetWindowPickerAlert(
            title: "Process Not Listed",
            message: "The selected window belongs to PID \(ownerPID), but that process is not present in the current snapshot. It may have exited, or macOS may be hiding it from the unprivileged sampler."
        )
    }

    private func finishTargetWindowPicker() {
        clearTargetWindowPickerMonitors()
        targetWindowPickerActive = false
        if targetWindowCursorPushed {
            NSCursor.pop()
            targetWindowCursorPushed = false
        }
    }

    private func clearTargetWindowPickerMonitors() {
        if let targetWindowGlobalMonitor {
            NSEvent.removeMonitor(targetWindowGlobalMonitor)
            self.targetWindowGlobalMonitor = nil
        }
        if let targetWindowLocalMonitor {
            NSEvent.removeMonitor(targetWindowLocalMonitor)
            self.targetWindowLocalMonitor = nil
        }
    }

    @discardableResult
    private func selectProcess(ownerPID: pid_t) -> Bool {
        guard let record = snapshot.processes.values.first(where: { $0.id.pid == ownerPID }) else {
            return false
        }
        selection = record.id
        return true
    }

    private static func windowOwnerPID(at appKitPoint: NSPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let hitTestPoints = targetWindowHitTestPoints(for: appKitPoint)
        for window in windows {
            guard intValue(window[kCGWindowLayer as String]) == 0,
                  let ownerPID = intValue(window[kCGWindowOwnerPID as String]),
                  ownerPID > 0,
                  let bounds = windowBounds(window),
                  bounds.width >= 8,
                  bounds.height >= 8
            else { continue }
            let alpha = doubleValue(window[kCGWindowAlpha as String]) ?? 1
            guard alpha > 0.02 else { continue }
            if hitTestPoints.contains(where: { bounds.contains($0) }) {
                return pid_t(ownerPID)
            }
        }
        return nil
    }

    private static func accessibilityOwnerPID(at appKitPoint: NSPoint) -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        for point in targetWindowHitTestPoints(for: appKitPoint) {
            var element: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
            guard result == .success, let element else { continue }
            var ownerPID = pid_t()
            if AXUIElementGetPid(element, &ownerPID) == .success, ownerPID > 0 {
                return ownerPID
            }
        }
        return nil
    }

    private static func noWindowPIDAlert() -> TargetWindowPickerAlert {
        if AXIsProcessTrusted() {
            return TargetWindowPickerAlert(
                title: "No Window Process Found",
                message: "The click did not hit an on-screen application window with an exposed process identifier. Try a visible app window rather than the desktop, menu bar, Dock, or a transient system surface."
            )
        }
        return TargetWindowPickerAlert(
            title: "No Window Process Found",
            message: "The CoreGraphics window list did not expose a process identifier for that point. Some system or protected windows can require Accessibility access. Grant ProcexpMac access in System Settings > Privacy & Security > Accessibility, then try again.",
            offersAccessibilitySettings: true
        )
    }

    private static func targetWindowHitTestPoints(for appKitPoint: NSPoint) -> [CGPoint] {
        var candidates = [CGPoint(x: appKitPoint.x, y: appKitPoint.y)]
        if let cgPoint = CGEvent(source: nil)?.location {
            candidates.append(cgPoint)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) {
            candidates.append(CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y))
            candidates.append(CGPoint(x: appKitPoint.x, y: screen.frame.minY + screen.frame.maxY - appKitPoint.y))
        }
        if let maxY = NSScreen.screens.map(\.frame.maxY).max() {
            candidates.append(CGPoint(x: appKitPoint.x, y: maxY - appKitPoint.y))
        }
        return candidates.reduce(into: []) { unique, candidate in
            let alreadyIncluded = unique.contains { existing in
                abs(existing.x - candidate.x) < 0.5 && abs(existing.y - candidate.y) < 0.5
            }
            if !alreadyIncluded { unique.append(candidate) }
        }
    }

    private static func windowBounds(_ window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        return nil
    }

    /// Merge cached signatures into a snapshot and schedule a bounded number of
    /// new lookups for paths not yet verified. Non-blocking: sampling is never
    /// held up by code-signing work. The "Verified Signer" column therefore
    /// fills in progressively over the first few refreshes.
    ///
    /// Throttling: at most `maxConcurrentSignatureLookups` lookups run at once,
    /// and no more than `maxNewSignatureLookupsPerRefresh` new ones are started
    /// per snapshot, so a fresh launch (~1000 processes) doesn't stampede the
    /// Security framework.
    private func enrichWithSignatures(_ snapshot: ProcessSnapshot) -> ProcessSnapshot {
        var processes = snapshot.processes
        var startedThisRefresh = 0

        for (id, record) in snapshot.processes {
            guard let path = record.executablePath else { continue }

            // Already resolved → merge the cached result.
            if let cached = signatureCache[path] {
                processes[id]?.signing = cached
                continue
            }

            // Otherwise schedule a lookup, respecting the setting + throttles.
            guard verifySignatures,
                  !signatureInFlight.contains(path),
                  signatureInFlight.count < maxConcurrentSignatureLookups,
                  startedThisRefresh < maxNewSignatureLookupsPerRefresh
            else { continue }

            signatureInFlight.insert(path)
            startedThisRefresh += 1
            let signing = self.signing
            Task { @MainActor in
                let info = await signing.signature(forPath: path)
                self.signatureCache[path] = info
                self.signatureInFlight.remove(path)
            }
        }

        return ProcessSnapshot(
            timestamp: snapshot.timestamp,
            interval: snapshot.interval,
            processes: processes,
            roots: snapshot.roots,
            children: snapshot.children,
            system: snapshot.system
        )
    }

    private func enrichWithCommandLines(_ snapshot: ProcessSnapshot) -> ProcessSnapshot {
        var processes = snapshot.processes
        var startedThisRefresh = 0
        let shouldFetch = columns.contains(.commandLine)

        for (id, record) in snapshot.processes {
            if let cached = commandLineCache[id] {
                if !cached.isEmpty { processes[id]?.commandLine = cached }
                continue
            }

            guard shouldFetch,
                  !commandLineInFlight.contains(id),
                  commandLineInFlight.count < maxConcurrentCommandLineLookups,
                  startedThisRefresh < maxNewCommandLineLookupsPerRefresh
            else { continue }

            commandLineInFlight.insert(id)
            startedThisRefresh += 1
            let data = self.data
            Task { @MainActor in
                let value = (try? await data.commandLine(of: id)) ?? ""
                self.commandLineCache[id] = value
                self.commandLineInFlight.remove(id)
            }
        }

        return ProcessSnapshot(
            timestamp: snapshot.timestamp,
            interval: snapshot.interval,
            processes: processes,
            roots: snapshot.roots,
            children: snapshot.children,
            system: snapshot.system
        )
    }

    private func enrichWithAutostart(_ snapshot: ProcessSnapshot) -> ProcessSnapshot {
        guard columns.contains(.autostart) else { return snapshot }
        var processes = snapshot.processes
        var startedThisRefresh = 0

        for (id, record) in snapshot.processes {
            guard let path = record.executablePath, !path.isEmpty else { continue }
            if let cached = autostartCache[path] {
                if !cached.isEmpty { processes[id]?.autostartLocation = cached }
                continue
            }

            guard !autostartInFlight.contains(path),
                  autostartInFlight.count < maxConcurrentAutostartLookups,
                  startedThisRefresh < maxNewAutostartLookupsPerRefresh
            else { continue }

            autostartInFlight.insert(path)
            startedThisRefresh += 1
            let autostart = self.autostart
            Task { @MainActor in
                let value = await autostart.autostartLocation(for: record) ?? ""
                self.autostartCache[path] = value
                self.autostartInFlight.remove(path)
            }
        }

        return ProcessSnapshot(
            timestamp: snapshot.timestamp,
            interval: snapshot.interval,
            processes: processes,
            roots: snapshot.roots,
            children: snapshot.children,
            system: snapshot.system
        )
    }

    /// R5 — compute the single top-consuming process for each tracked resource
    /// in one pass over the snapshot, and append to the parallel "top" rings so
    /// they stay index-aligned with the numeric history rings.
    private func appendTopConsumers(for snap: ProcessSnapshot) {
        var cpu = TopConsumer.none
        var mem = TopConsumer.none
        var io = TopConsumer.none
        var net = TopConsumer.none
        var gpu = TopConsumer.none

        for record in snap.processes.values {
            if record.cpuPercent > cpu.value {
                cpu = TopConsumer(name: record.name, value: record.cpuPercent)
            }
            let memBytes = Double(record.physFootprint ?? record.residentSize)
            if memBytes > mem.value {
                mem = TopConsumer(name: record.name, value: memBytes)
            }
            let ioBytes = Double((record.diskBytesRead ?? 0) + (record.diskBytesWritten ?? 0))
            if ioBytes > io.value {
                io = TopConsumer(name: record.name, value: ioBytes)
            }
            let netBytes = Double(record.networkBytesPerSec ?? 0)
            if netBytes > net.value {
                net = TopConsumer(name: record.name, value: netBytes)
            }
            let gpuPct = record.gpuPercent ?? 0
            if gpuPct > gpu.value {
                gpu = TopConsumer(name: record.name, value: gpuPct)
            }
        }

        cpuTopHistory.append(cpu)
        memoryTopHistory.append(mem)
        ioTopHistory.append(io)
        networkTopHistory.append(net)
        gpuTopHistory.append(gpu)
    }

    /// Apply the selected appearance to the whole application.
    func applyTheme() {
        NSApp?.appearance = theme.nsAppearance
    }

    /// Raise or lower the main window's level to keep it above other apps.
    func applyAlwaysOnTop() {
        let level: NSWindow.Level = alwaysOnTop ? .floating : .normal
        for window in NSApp?.windows ?? [] where window.title == "Sysinternals Process Explorer" {
            window.level = level
        }
    }
}

/// R5 — the top-consuming process for a resource at a single sampled moment.
/// Recorded per tick alongside the numeric history rings so graph tooltips can
/// show "who dominated this resource" at any point on the timeline.
struct TopConsumer: Sendable, Equatable {
    var name: String
    var value: Double

    /// Sentinel used when a snapshot has no processes for a resource.
    static let none = TopConsumer(name: "—", value: 0)

    /// Whether a real consumer was recorded (as opposed to the sentinel).
    var isValid: Bool { value > 0 && name != "—" }
}

/// Window appearance choices (Options ▸ Theme).
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` follows the system appearance; otherwise a concrete aqua variant.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
