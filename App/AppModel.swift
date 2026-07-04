//
//  AppModel.swift
//  Central observable app state. Owns the data providers and the latest
//  process snapshot, and drives the refresh loop.
//

import Foundation
import Observation
import AppKit
import ProcexpModel
import ProcexpSampling
import ProcexpSigning
import ProcexpNetwork
import ProcexpGraphs
import ProcexpAutostart
import ProcexpActions
import ProcexpPrivileged

@MainActor
@Observable
final class AppModel {
    // Latest sampled state.
    var snapshot: ProcessSnapshot = .empty
    var selection: ProcessID?

    // View configuration. `didSet` observers persist changes (W11) once the
    // stored settings have finished loading at launch.
    var refreshInterval: TimeInterval = 1.0 { didSet { persistSettings() } }
    var columns: [Column] = Column.defaultColumns { didSet { persistSettings() } }
    var processColumnWidth: Double = 430 { didSet { persistSettings() } }
    var columnWidths: [String: Double] = [:] { didSet { persistSettings() } }
    var colorRules: [ProcessColorRule] = ProcessColorRule.defaults { didSet { persistSettings() } }
    var useMockData: Bool = false { didSet { persistSettings() } }

    // W11 preference toggles.
    var confirmBeforeKill: Bool = true { didSet { persistSettings() } }
    var verifySignatures: Bool = true { didSet { persistSettings() } }
    var differenceHighlightDuration: TimeInterval = 1.0 { didSet { persistSettings() } }

    /// Gate so restoring persisted settings at launch doesn't immediately
    /// re-save them (and so `init` assignments are never persisted early).
    private var settingsLoaded = false

    // W5 lower-pane view state (mapped images vs. file descriptors).
    var showLowerPane: Bool = true
    var lowerPaneMode: LowerPaneMode = .modules

    // R1 — show the process hierarchy (tree) vs. a flat list of all processes
    // (Procexp "View ▸ Show Process Tree", ⌘T).
    var showProcessTree: Bool = true

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
    /// Bumped to request focus of the filter field (Find ▸ Filter Processes, ⇧⌘F).
    var focusSearchToken: Int = 0
    /// Bumped to request saving the process list (File ▸ Save, ⌘S).
    var saveRequestToken: Int = 0

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

    /// Begin (or restart) the snapshot stream at the current refresh interval.
    func start() async {
        streamTask?.cancel()
        // R1 — honour the paused state: stop streaming entirely.
        guard !paused else {
            streamTask = nil
            return
        }
        let provider: any ProcessDataProviding = useMockData ? MockDataProvider() : data
        let interval = refreshInterval
        let system = self.system
        streamTask = Task { @MainActor in
            for await snap in provider.snapshots(interval: interval) {
                self.snapshot = self.enrichWithSignatures(snap)
                let stats = await system.stats()
                self.cpuHistory.append(stats.cpuTotalPercent)
                let memPct = stats.memoryTotal > 0
                    ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
                    : 0
                self.memoryHistory.append(memPct)

                // W4 — record the remaining System Information series.
                self.swapHistory.append(Double(stats.swapUsed))
                self.diskHistory.append(Double(stats.diskBytesPerSec))
                self.networkHistory.append(Double(stats.networkBytesPerSec))
                self.gpuHistory.append(stats.gpuPercent ?? 0)

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
        let provider: any ProcessDataProviding = useMockData ? MockDataProvider() : data
        let snap = await provider.snapshot()
        self.snapshot = self.enrichWithSignatures(snap)
        let stats = await system.stats()
        cpuHistory.append(stats.cpuTotalPercent)
        let memPct = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0
        memoryHistory.append(memPct)
        ioHistory.append(Double(stats.diskBytesPerSec) + Double(stats.networkBytesPerSec))
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
