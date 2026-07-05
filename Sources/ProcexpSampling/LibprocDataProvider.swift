//
//  LibprocDataProvider.swift
//  ProcexpSampling — W1 (unprivileged sampling engine)
//
//  A real `ProcessDataProviding` implementation backed by macOS `libproc` and
//  `sysctl`. It runs entirely unprivileged: it enumerates every process and
//  fills as much of `ProcessRecord` as the kernel exposes without a task port.
//  Anything that genuinely requires elevated rights (per-thread CPU, other
//  users' argv/env, task-port introspection) is left to the W2 privileged
//  helper and degraded gracefully here.
//

import Foundation
import Darwin
import ProcexpModel

public final class LibprocDataProvider: ProcessDataProviding, Sendable {

    private let cpuTracker = CPUDeltaTracker()
    private let memoryTotal: UInt64
    private let supportsModules: Bool

    public init() {
        self.memoryTotal = Libproc.physicalMemory()
        // Probe region enumeration once against our own process to decide
        // whether the `.modules` capability can be advertised.
        self.supportsModules = !Libproc.modules(getpid()).isEmpty
    }

    public var capabilities: ProviderCapabilities {
        var caps: ProviderCapabilities = [.accurateCPU]
        if supportsModules { caps.insert(.modules) }
        return caps
    }

    // MARK: - Streaming

    public func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot> {
        let tracker = cpuTracker
        let memoryTotal = self.memoryTotal
        return AsyncStream { continuation in
            let task = Task {
                await tracker.reset()
                // Immediate first frame (CPU% is zero until we have a delta).
                continuation.yield(
                    await Self.sample(interval: interval, tracker: tracker, memoryTotal: memoryTotal)
                )
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    continuation.yield(
                        await Self.sample(interval: interval, tracker: tracker, memoryTotal: memoryTotal)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func snapshot() async -> ProcessSnapshot {
        await Self.sample(interval: 0, tracker: cpuTracker, memoryTotal: memoryTotal)
    }

    // MARK: - One sampling pass

    private static func sample(
        interval: TimeInterval,
        tracker: CPUDeltaTracker,
        memoryTotal: UInt64
    ) async -> ProcessSnapshot {
        let myUID = getuid()
        let pids = Libproc.allPIDs()

        var records: [ProcessID: ProcessRecord] = [:]
        var pidToID: [pid_t: ProcessID] = [:]
        var ppids: [ProcessID: pid_t] = [:]
        var cpuTimes: [ProcessID: UInt64] = [:]

        records.reserveCapacity(pids.count)
        pidToID.reserveCapacity(pids.count)

        var totalThreads = 0
        var totalFDs = 0

        for pid in pids {
            guard let built = buildRecord(pid: pid, myUID: myUID) else { continue }
            records[built.record.id] = built.record
            pidToID[pid] = built.record.id
            ppids[built.record.id] = built.ppid
            cpuTimes[built.record.id] = built.record.cpuTime
            totalThreads += built.record.threadCount
            totalFDs += built.record.fileDescriptorCount ?? 0
        }

        // Resolve parent identities now that every PID → ProcessID is known.
        for (id, ppid) in ppids {
            if ppid != 0, let parentID = pidToID[ppid], parentID != id {
                records[id]?.parent = parentID
            }
        }

        // Turn cumulative CPU time into an instantaneous percentage.
        let percentages = await tracker.percentages(
            current: cpuTimes,
            wallNanos: Libproc.nowNanos()
        )
        for (id, pct) in percentages {
            records[id]?.cpuPercent = pct
        }

        let (roots, children) = ProcessTreeBuilder.build(from: records)

        let system = SystemStats(
            cpuTotalPercent: 0,          // W4 owns full system CPU.
            perCoreCPUPercent: [],       // W4 owns per-core CPU.
            memoryUsed: 0,
            memoryTotal: memoryTotal,
            memoryWired: 0,
            memoryCompressed: 0,
            swapUsed: 0,
            diskBytesPerSec: 0,
            networkBytesPerSec: 0,
            gpuPercent: nil,
            processCount: records.count,
            threadCount: totalThreads,
            handleCount: totalFDs
        )

        return ProcessSnapshot(
            timestamp: Date(),
            interval: interval,
            processes: records,
            roots: roots,
            children: children,
            system: system
        )
    }

    private struct BuiltRecord {
        var record: ProcessRecord
        var ppid: pid_t
    }

    /// Assemble a `ProcessRecord` for one PID. Returns `nil` only if the process
    /// has already gone (no BSD info) — a dying PID never crashes the pass.
    private static func buildRecord(pid: pid_t, myUID: uid_t) -> BuiltRecord? {
        guard let bsd = Libproc.bsdInfo(pid) else {
            // Full BSD info is EPERM for SIP-protected processes (e.g. launchd).
            // Fall back to short BSD info so the process still appears.
            return buildShortRecord(pid: pid, myUID: myUID)
        }

        let startSeconds = bsd.pbi_start_tvsec
        let procID = ProcessID(pid: pid, startTime: startSeconds)
        let startDate = Date(
            timeIntervalSince1970: Double(startSeconds) + Double(bsd.pbi_start_tvusec) / 1_000_000
        )

        let uid = bsd.pbi_uid
        let ppid = pid_t(bitPattern: bsd.pbi_ppid)

        // Name: prefer proc_name, then registered name, then comm, then exe.
        let path = Libproc.path(pid)
        var name = Libproc.name(pid)
        if name.isEmpty { name = Libproc.fixedChars(bsd.pbi_name) }
        if name.isEmpty { name = Libproc.fixedChars(bsd.pbi_comm) }
        if name.isEmpty, let path { name = (path as NSString).lastPathComponent }
        if name.isEmpty { name = "pid \(pid)" }

        // Task info: CPU / threads / memory / faults (may be absent w/o access).
        var task = Libproc.TaskInfoDetails()
        var hasTaskInfo = false
        if let ti = Libproc.taskInfo(pid) {
            hasTaskInfo = true
            task = Libproc.taskDetails(ti)
        }

        // Descriptor count (handle-equivalent).
        let fdCount = Libproc.fdCount(pid)

        // Disk I/O + phys footprint — own processes only; ignore failures.
        var diskRead: UInt64? = nil
        var diskWritten: UInt64? = nil
        var physFootprint: UInt64? = nil
        if uid == myUID, let usage = Libproc.rusage(pid) {
            diskRead = usage.diskRead
            diskWritten = usage.diskWritten
            physFootprint = usage.physFootprint
        }

        var flags: ProcessFlags = []
        if uid == myUID { flags.insert(.ownProcess) }
        if Self.isSystemDaemon(ppid: ppid, uid: uid) { flags.insert(.service) }
        if !hasTaskInfo { flags.insert(.limitedTaskInfo) }
        let bsdFlags = bsd.pbi_flags
        let hasTTY = (bsdFlags & UInt32(PROC_FLAG_CONTROLT)) != 0
        let sessionTTY = Libproc.sessionTTY(device: bsd.e_tdev, hasControllingTTY: hasTTY)

        // Static bundle metadata (version / description / company). Cached by
        // executable path so repeat samples don't re-read Info.plist.
        let meta = path.map { BundleMetadataCache.shared.metadata(forExecutablePath: $0) }

        let record = ProcessRecord(
            id: procID,
            parent: nil,                    // resolved in a second pass
            name: name,
            executablePath: path,
            bundleIdentifier: meta?.bundleIdentifier,
            iconPath: meta?.bundlePath,
            imageType: imageType(path: path, ppid: ppid, uid: uid),
            uid: uid,
            userName: Libproc.userName(for: uid),
            sessionTTY: sessionTTY,
            bsdFlagsRaw: bsdFlags,
            bsdStatusRaw: bsd.pbi_status,
            hasControllingTTY: hasTTY,
            isSessionLeader: (bsdFlags & UInt32(PROC_FLAG_SLEADER)) != 0,
            is64Bit: (bsdFlags & UInt32(PROC_FLAG_LP64)) != 0,
            displayDescription: meta?.displayDescription,
            companyName: meta?.companyName,
            version: meta?.version,
            cpuPercent: 0,                  // filled after delta computation
            cpuTime: task.cpuTime,
            threadCount: task.threadCount,
            runningThreadCount: task.runningThreadCount,
            threadUserTime: task.threadUserTime,
            threadSystemTime: task.threadSystemTime,
            taskPolicy: task.taskPolicy,
            contextSwitches: task.contextSwitches,
            residentSize: task.residentSize,
            virtualSize: task.virtualSize,
            physFootprint: physFootprint,
            pageFaults: task.pageFaults,
            pageIns: task.pageIns,
            copyOnWriteFaults: task.copyOnWriteFaults,
            machMessagesSent: task.machMessagesSent,
            machMessagesReceived: task.machMessagesReceived,
            machSyscalls: task.machSyscalls,
            unixSyscalls: task.unixSyscalls,
            diskBytesRead: diskRead,
            diskBytesWritten: diskWritten,
            fileDescriptorCount: fdCount,
            nice: bsd.pbi_nice,
            priority: task.priority,
            flags: flags,
            startTimeDate: startDate
        )
        return BuiltRecord(record: record, ppid: ppid)    }

    /// Minimal record built from short BSD info (available for every pid) when
    /// full BSD info is denied. Start time is unavailable here, so identity
    /// falls back to `startTime: 0`; name/ppid/uid and best-effort task/fd
    /// counts are still populated.
    private static func buildShortRecord(pid: pid_t, myUID: uid_t) -> BuiltRecord? {
        guard let sbsd = Libproc.shortBsdInfo(pid) else { return nil }

        let procID = ProcessID(pid: pid, startTime: 0)
        let uid = sbsd.pbsi_uid
        let ppid = pid_t(bitPattern: sbsd.pbsi_ppid)

        let path = Libproc.path(pid)
        var name = Libproc.name(pid)
        if name.isEmpty { name = Libproc.fixedChars(sbsd.pbsi_comm) }
        if name.isEmpty, let path { name = (path as NSString).lastPathComponent }
        if name.isEmpty { name = "pid \(pid)" }

        var task = Libproc.TaskInfoDetails()
        var hasTaskInfo = false
        if let ti = Libproc.taskInfo(pid) {
            hasTaskInfo = true
            task = Libproc.taskDetails(ti)
        }

        var flags: ProcessFlags = []
        if uid == myUID { flags.insert(.ownProcess) }
        if Self.isSystemDaemon(ppid: ppid, uid: uid) { flags.insert(.service) }
        if !hasTaskInfo { flags.insert(.limitedTaskInfo) }
        let bsdFlags = sbsd.pbsi_flags
        let hasTTY = (bsdFlags & UInt32(PROC_FLAG_CONTROLT)) != 0

        let meta = path.map { BundleMetadataCache.shared.metadata(forExecutablePath: $0) }

        let record = ProcessRecord(
            id: procID,
            parent: nil,
            name: name,
            executablePath: path,
            bundleIdentifier: meta?.bundleIdentifier,
            iconPath: meta?.bundlePath,
            imageType: imageType(path: path, ppid: ppid, uid: uid),
            uid: uid,
            userName: Libproc.userName(for: uid),
            bsdFlagsRaw: bsdFlags,
            bsdStatusRaw: sbsd.pbsi_status,
            hasControllingTTY: hasTTY,
            isSessionLeader: (bsdFlags & UInt32(PROC_FLAG_SLEADER)) != 0,
            is64Bit: (bsdFlags & UInt32(PROC_FLAG_LP64)) != 0,
            displayDescription: meta?.displayDescription,
            companyName: meta?.companyName,
            version: meta?.version,
            cpuPercent: 0,
            cpuTime: task.cpuTime,
            threadCount: task.threadCount,
            runningThreadCount: task.runningThreadCount,
            threadUserTime: task.threadUserTime,
            threadSystemTime: task.threadSystemTime,
            taskPolicy: task.taskPolicy,
            contextSwitches: task.contextSwitches,
            residentSize: task.residentSize,
            virtualSize: task.virtualSize,
            pageFaults: task.pageFaults,
            pageIns: task.pageIns,
            copyOnWriteFaults: task.copyOnWriteFaults,
            machMessagesSent: task.machMessagesSent,
            machMessagesReceived: task.machMessagesReceived,
            machSyscalls: task.machSyscalls,
            unixSyscalls: task.unixSyscalls,
            fileDescriptorCount: Libproc.fdCount(pid),
            nice: 0,
            priority: task.priority,
            flags: flags,
            startTimeDate: .distantPast
        )
        return BuiltRecord(record: record, ppid: ppid)
    }

    private static func imageType(path: String?, ppid: pid_t, uid: uid_t) -> ImageType {
        guard let path else {
            return isSystemDaemon(ppid: ppid, uid: uid) ? .daemon : .unknown
        }
        if path.contains(".app/Contents/MacOS/") { return .appBundle }
        if path.hasSuffix(".xpc") || path.contains(".xpc/Contents/MacOS/") { return .xpc }
        if isSystemDaemon(ppid: ppid, uid: uid) { return .daemon }
        return .cli
    }

    /// Whether a process looks like a launchd-managed system daemon (a
    /// Process Explorer "service").
    ///
    /// A daemon is a direct child of launchd (`ppid == 1`) running under a
    /// system account. macOS reserves UIDs below 500 for system/service
    /// accounts — root plus the dedicated `_service` users such as
    /// `_corespeechd`, `_locationd`, and `_coreaudiod` — while real user
    /// accounts start at 501. Gating on root alone (`uid == 0`) misses the many
    /// system daemons that run under a non-root service account for privilege
    /// separation, so they would not be colored as services.
    private static func isSystemDaemon(ppid: pid_t, uid: uid_t) -> Bool {
        ppid == 1 && uid < 500
    }

    // MARK: - Per-selection detail

    public func threads(of id: ProcessID) async throws -> [ThreadInfo] {
        guard let ti = Libproc.taskInfo(id.pid) else { return [] }
        let n = Int(ti.pti_threadnum)
        guard n > 0 else { return [] }

        let details = Libproc.threads(id.pid, expectedCount: n)
        if !details.isEmpty { return details }

        // Fall back to one stub per live thread when macOS refuses public
        // per-thread detail. The privileged helper can still fill richer data
        // for protected/other-user processes when task ports are available.
        return (0..<n).map { index in
            ThreadInfo(
                id: UInt64(index),
                cpuPercent: 0,
                cpuTime: 0,
                state: "",
                startAddress: nil,
                startSymbol: nil,
                basePriority: ti.pti_priority
            )
        }
    }

    public func modules(of id: ProcessID) async throws -> [ModuleInfo] {
        Libproc.modules(id.pid)
    }

    public func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo] {
        Libproc.fileDescriptors(id.pid)
    }

    public func commandLine(of id: ProcessID) async throws -> String? {
        guard let args = Libproc.procArgs(id.pid) else { throw ProviderError.notPermitted }
        return args.arguments.isEmpty ? nil : args.arguments.joined(separator: " ")
    }

    public func environment(of id: ProcessID) async throws -> [String: String] {
        guard let args = Libproc.procArgs(id.pid) else { throw ProviderError.notPermitted }
        return args.environment
    }

    public func currentDirectory(of id: ProcessID) async throws -> String? {
        Libproc.currentDirectory(id.pid)
    }

    public func strings(of id: ProcessID) async throws -> [String] {
        guard let path = Libproc.path(id.pid) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Libproc.strings(atPath: path)
        }.value
    }
}
