//
//  MockDataProvider.swift
//  ProcexpModel — W0 shared contracts
//
//  A fully-functional fake data source so every UI and feature workstream can
//  build and run before the real sampling engine (W1) exists. Generates ~150
//  processes in a realistic tree, animates CPU/memory/I-O each tick, and
//  occasionally spawns/kills a process to exercise diff highlighting.
//

import Foundation

/// Conforms to all read-side provider protocols with realistic synthetic data.
public final class MockDataProvider: ProcessDataProviding, NetworkProviding,
                                     SystemStatsProviding, SigningProviding,
                                     AutostartProviding, @unchecked Sendable {

    private let world: World

    public init(seed: UInt64 = 0x50524F43_4558504D) {
        self.world = World(seed: seed)
    }

    public var capabilities: ProviderCapabilities {
        [.accurateCPU, .modules, .fullEnvironment]
    }

    // MARK: ProcessDataProviding

    public func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot> {
        let world = self.world
        return AsyncStream { continuation in
            let task = Task {
                // Emit an immediate first frame.
                continuation.yield(await world.step(interval: interval))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    continuation.yield(await world.step(interval: interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func snapshot() async -> ProcessSnapshot {
        await world.currentSnapshot()
    }

    public func threads(of id: ProcessID) async throws -> [ThreadInfo] {
        await world.threads(of: id)
    }

    public func modules(of id: ProcessID) async throws -> [ModuleInfo] {
        await world.modules(of: id)
    }

    public func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo] {
        await world.fileDescriptors(of: id)
    }

    public func commandLine(of id: ProcessID) async throws -> String? {
        await world.info(id)?.executablePath
    }

    public func environment(of id: ProcessID) async throws -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/demo", "SHELL": "/bin/zsh"]
    }

    public func currentDirectory(of id: ProcessID) async throws -> String? { "/Users/demo" }

    public func strings(of id: ProcessID) async throws -> [String] {
        ["/usr/lib/dyld", "__mh_execute_header", "main", "NSApplicationMain",
         "%s: %d", "Unable to open file", "libSystem.B.dylib"]
    }

    // MARK: NetworkProviding

    public func sockets(of id: ProcessID) async throws -> [SocketInfo] {
        await world.sockets(of: id)
    }

    public func networkRates() async -> [ProcessID: UInt64] {
        await world.networkRates()
    }

    // MARK: SystemStatsProviding

    public func stats() async -> SystemStats {
        await world.currentSnapshot().system
    }

    // MARK: SigningProviding

    public func signature(forPath path: String) async -> SignatureInfo {
        let apple = path.hasPrefix("/System") || path.hasPrefix("/usr") || path.hasPrefix("/bin")
        return SignatureInfo(
            status: .signed,
            teamID: apple ? nil : "ABCDE12345",
            authority: apple ? ["Software Signing", "Apple Code Signing Certification Authority"]
                             : ["Developer ID Application: Example Corp (ABCDE12345)"],
            isNotarized: !apple,
            isPlatformBinary: apple,
            isAdHoc: false,
            sha256: String(repeating: "a", count: 64)
        )
    }

    public func virusTotal(sha256: String) async throws -> VirusTotalResult? {
        VirusTotalResult(positives: 0, total: 73, permalink: nil, checkedAt: Date())
    }

    // MARK: AutostartProviding

    public func autostartLocation(for process: ProcessRecord) async -> String? {
        process.flags.contains(.service)
            ? "/Library/LaunchDaemons/\(process.name).plist"
            : nil
    }
}

// MARK: - Evolving synthetic world

private actor World {
    private var processes: [ProcessID: ProcessRecord] = [:]
    private var rng: SplitMix64
    private var tick: UInt64 = 0
    private var nextPID: Int32 = 5000
    private var lastSnapshot: ProcessSnapshot = .empty

    private let coreCount = 8
    private var cpuHistorySeed: Double = 0.2

    init(seed: UInt64) {
        var r = SplitMix64(seed: seed)
        let seeded = World.seedInitialTree(rng: &r)
        self.rng = r
        self.processes = seeded.processes
        self.nextPID = seeded.nextPID
        // lastSnapshot stays `.empty`; the first `snapshot()`/`step()` builds it.
    }

    func info(_ id: ProcessID) -> ProcessRecord? { processes[id] }

    // Build ~150 processes in a believable tree. `nonisolated static` so it can
    // run during `init` without crossing actor isolation; it operates purely on
    // locals and the passed-in RNG and returns the built state.
    private static func seedInitialTree(
        rng: inout SplitMix64
    ) -> (processes: [ProcessID: ProcessRecord], nextPID: Int32) {
        var processes: [ProcessID: ProcessRecord] = [:]
        var nextPID: Int32 = 5000
        let now = Date()
        func make(
            _ pid: Int32,
            _ name: String,
            parent: ProcessID?,
            path: String,
            flags: ProcessFlags = [],
            uid: UInt32 = 501,
            user: String = "demo"
        ) -> ProcessRecord {
            let id = ProcessID(pid: pid, startTime: 1_700_000_000)
            var info = ProcessRecord(
                id: id,
                parent: parent,
                name: name,
                executablePath: path,
                bundleIdentifier: name.contains(".") ? name : "com.example.\(name)",
                iconPath: path,
                imageType: path.hasSuffix(".app") || path.contains(".app/") ? .appBundle : .cli,
                uid: uid,
                userName: user,
                sessionTTY: uid == 0 ? nil : "ttys000",
                displayDescription: name.capitalized,
                companyName: flags.contains(.service) ? "Apple Inc." : "Example Corp",
                version: "1.\(pid % 20).0",
                cpuPercent: 0,
                cpuTime: UInt64(rng.next() % 5_000_000_000),
                threadCount: 1 + Int(rng.next() % 24),
                residentSize: (10 + rng.next() % 400) * 1024 * 1024,
                virtualSize: (400 + rng.next() % 4000) * 1024 * 1024,
                physFootprint: (8 + rng.next() % 300) * 1024 * 1024,
                pageFaults: rng.next() % 500_000,
                diskBytesRead: rng.next() % (2 * 1024 * 1024 * 1024),
                diskBytesWritten: rng.next() % (1024 * 1024 * 1024),
                fileDescriptorCount: 3 + Int(rng.next() % 200),
                nice: 0,
                priority: 31,
                flags: flags,
                startTimeDate: now.addingTimeInterval(-Double(rng.next() % 86_400))
            )
            info.networkBytesPerSec = flags.contains(.service) ? rng.next() % 200_000 : 0
            return info
        }

        // Roots
        let launchd = make(1, "launchd", parent: nil, path: "/sbin/launchd",
                           flags: [.service, .platformBinary], uid: 0, user: "root")
        processes[launchd.id] = launchd

        let systemDaemons = [
            "kernel_task", "UserEventAgent", "cfprefsd", "distnoted", "coreaudiod",
            "WindowServer", "loginwindow", "syslogd", "powerd", "bluetoothd",
            "mDNSResponder", "notifyd", "opendirectoryd", "securityd", "diskarbitrationd",
            "hidd", "fseventsd", "configd", "logd", "nsurlsessiond"
        ]
        for (i, name) in systemDaemons.enumerated() {
            let p = make(Int32(100 + i), name, parent: launchd.id,
                         path: "/usr/libexec/\(name)",
                         flags: [.service, .platformBinary],
                         uid: 0, user: "root")
            processes[p.id] = p
        }

        // A user session under launchd
        let userLaunchd = make(400, "launchd", parent: launchd.id, path: "/sbin/launchd",
                               flags: [.platformBinary], uid: 0, user: "root")
        processes[userLaunchd.id] = userLaunchd

        let userAgents = [
            "Dock", "Finder", "SystemUIServer", "NotificationCenter", "Spotlight",
            "controlcenter", "TextInputMenuAgent", "talagent", "universalaccessd"
        ]
        for (i, name) in userAgents.enumerated() {
            let p = make(Int32(500 + i), name, parent: userLaunchd.id,
                         path: "/System/Library/CoreServices/\(name).app/Contents/MacOS/\(name)",
                         flags: [.platformBinary], uid: 501)
            processes[p.id] = p
        }

        // User apps with helper children (the interesting, colorful part)
        struct AppSpec { let name: String; let helpers: [String]; let sandboxed: Bool }
        let apps: [AppSpec] = [
            AppSpec(name: "Safari", helpers: ["com.apple.WebKit.WebContent", "com.apple.WebKit.Networking", "com.apple.WebKit.GPU"], sandboxed: true),
            AppSpec(name: "Code", helpers: ["Code Helper", "Code Helper (Renderer)", "Code Helper (GPU)", "Code Helper (Plugin)"], sandboxed: false),
            AppSpec(name: "Terminal", helpers: ["zsh", "zsh", "git"], sandboxed: false),
            AppSpec(name: "Mail", helpers: ["com.apple.mail.spotlight"], sandboxed: true),
            AppSpec(name: "Music", helpers: ["MusicCache"], sandboxed: true),
            AppSpec(name: "Slack", helpers: ["Slack Helper", "Slack Helper (Renderer)", "Slack Helper (GPU)"], sandboxed: true),
            AppSpec(name: "Docker", helpers: ["com.docker.backend", "com.docker.vpnkit", "qemu-system"], sandboxed: false),
            AppSpec(name: "Xcode", helpers: ["SourceKitService", "swift-frontend", "clangd", "IBAgent"], sandboxed: false),
        ]
        for spec in apps {
            let appPID = nextPID; nextPID += 1
            var flags: ProcessFlags = [.ownProcess]
            if spec.sandboxed { flags.insert(.sandboxed) }
            let app = make(appPID, spec.name, parent: userLaunchd.id,
                           path: "/Applications/\(spec.name).app/Contents/MacOS/\(spec.name)",
                           flags: flags, uid: 501)
            processes[app.id] = app
            for helper in spec.helpers {
                let hp = nextPID; nextPID += 1
                var hflags: ProcessFlags = [.ownProcess]
                if spec.sandboxed { hflags.insert(.sandboxed) }
                let child = make(hp, helper, parent: app.id,
                                 path: "/Applications/\(spec.name).app/Contents/Frameworks/\(helper)",
                                 flags: hflags, uid: 501)
                processes[child.id] = child
            }
        }

        // Pad up to ~150 with anonymous background helpers.
        while processes.count < 150 {
            let pid = nextPID; nextPID += 1
            let p = make(pid, "helper\(pid)", parent: launchd.id,
                         path: "/usr/libexec/helper\(pid)",
                         flags: [.service, .platformBinary], uid: 0, user: "root")
            processes[p.id] = p
        }

        return (processes, nextPID)
    }

    /// Advance the simulation one tick and return the new snapshot.
    func step(interval: TimeInterval) -> ProcessSnapshot {
        tick &+= 1

        // Age out any dead-flagged processes from the previous tick.
        for (id, info) in processes where info.flags.contains(.deadProcess) {
            processes[id] = nil
        }
        // Clear transient new flags.
        for (id, var info) in processes where info.flags.contains(.newProcess) {
            info.flags.remove(.newProcess)
            processes[id] = info
        }

        // Animate metrics.
        for (id, var info) in processes {
            let base = Double((id.pid % 7)) * 0.6
            let wobble = (Double(rng.next() % 1000) / 1000.0)
            let busy = max(0, base + sin(Double(tick) * 0.3 + Double(id.pid)) * 3 + wobble * 2)
            info.cpuPercent = info.flags.contains(.suspended) ? 0 : busy
            info.cpuTime &+= UInt64(busy * interval * 1_000_000)
            let d = Int64(rng.next() % 8 * 1024 * 1024) - 4 * 1024 * 1024
            info.residentSize = UInt64(max(4 * 1024 * 1024, Int64(info.residentSize) + d))
            info.physFootprint = info.residentSize
            info.diskBytesRead = (info.diskBytesRead ?? 0) &+ rng.next() % 400_000
            info.diskBytesWritten = (info.diskBytesWritten ?? 0) &+ rng.next() % 200_000
            if info.networkBytesPerSec != nil {
                info.networkBytesPerSec = rng.next() % 500_000
            }
            processes[id] = info
        }

        // Occasionally toggle a suspend on a user app to exercise coloring.
        if tick % 7 == 0, let victim = processes.values.first(where: { $0.flags.contains(.ownProcess) }) {
            var v = victim
            if v.flags.contains(.suspended) { v.flags.remove(.suspended) } else { v.flags.insert(.suspended) }
            processes[v.id] = v
        }

        // Spawn a new process every few ticks (green highlight).
        if tick % 4 == 0 {
            let pid = nextPID; nextPID += 1
            let id = ProcessID(pid: pid, startTime: 1_700_000_000 &+ tick)
            let parent = processes.values.first { $0.flags.contains(.ownProcess) }?.id
            var p = ProcessRecord(
                id: id, parent: parent, name: "spawned\(pid)",
                executablePath: "/tmp/spawned\(pid)", imageType: .cli,
                uid: 501, userName: "demo", displayDescription: "Spawned Task",
                companyName: "Example Corp", version: "1.0",
                cpuPercent: 1, threadCount: 2, residentSize: 12 * 1024 * 1024,
                virtualSize: 500 * 1024 * 1024, physFootprint: 12 * 1024 * 1024,
                fileDescriptorCount: 8, nice: 0, priority: 31,
                flags: [.ownProcess, .newProcess], startTimeDate: Date()
            )
            p.diskBytesRead = 0; p.diskBytesWritten = 0
            processes[id] = p
        }

        // Kill a spawned process every few ticks (red highlight for one frame).
        if tick % 5 == 0, let victim = processes.values.first(where: { $0.name.hasPrefix("spawned") && !$0.flags.contains(.deadProcess) }) {
            var v = victim
            v.flags.insert(.deadProcess)
            v.cpuPercent = 0
            processes[v.id] = v
        }

        return rebuild(interval: interval)
    }

    @discardableResult
    private func rebuild(interval: TimeInterval) -> ProcessSnapshot {
        let (roots, children) = ProcessTreeBuilder.build(from: processes)
        let totalThreads = processes.values.reduce(0) { $0 + $1.threadCount }
        let totalFDs = processes.values.reduce(0) { $0 + ($1.fileDescriptorCount ?? 0) }
        let avgCPU = processes.values.reduce(0.0) { $0 + $1.cpuPercent }
        cpuHistorySeed = min(100, max(0, avgCPU / Double(coreCount)))

        let perCore = (0..<coreCount).map { core -> Double in
            min(100, max(0, cpuHistorySeed + sin(Double(tick) * 0.4 + Double(core)) * 15 + 20))
        }
        let system = SystemStats(
            cpuTotalPercent: perCore.reduce(0, +) / Double(coreCount),
            perCoreCPUPercent: perCore,
            memoryUsed: 12 * 1024 * 1024 * 1024,
            memoryTotal: 32 * 1024 * 1024 * 1024,
            memoryWired: 4 * 1024 * 1024 * 1024,
            memoryCompressed: 2 * 1024 * 1024 * 1024,
            swapUsed: 512 * 1024 * 1024,
            diskBytesPerSec: rng.next() % (200 * 1024 * 1024),
            networkBytesPerSec: rng.next() % (50 * 1024 * 1024),
            gpuPercent: Double(rng.next() % 100),
            processCount: processes.count,
            threadCount: totalThreads,
            handleCount: totalFDs
        )
        let snap = ProcessSnapshot(
            timestamp: Date(),
            interval: interval,
            processes: processes,
            roots: roots,
            children: children,
            system: system
        )
        lastSnapshot = snap
        return snap
    }

    func currentSnapshot() -> ProcessSnapshot {
        lastSnapshot.processes.isEmpty ? rebuild(interval: 1) : lastSnapshot
    }

    func threads(of id: ProcessID) -> [ThreadInfo] {
        guard let info = processes[id] else { return [] }
        var result: [ThreadInfo] = []
        result.reserveCapacity(info.threadCount)
        for i in 0..<info.threadCount {
            let tid: UInt64 = (UInt64(id.pid) << 16) | UInt64(i)
            let cpu: Double = Double(rng.next() % 200) / 100.0
            let addr: UInt64 = 0x1_0000_0000 + UInt64(i) * 0x1000
            result.append(ThreadInfo(
                id: tid,
                cpuPercent: cpu,
                cpuTime: rng.next() % 1_000_000_000,
                state: i == 0 ? "running" : "waiting",
                startAddress: addr,
                startSymbol: i == 0 ? "main" : "thread_start",
                basePriority: 31
            ))
        }
        return result
    }

    func modules(of id: ProcessID) -> [ModuleInfo] {
        guard let info = processes[id] else { return [] }
        var mods: [ModuleInfo] = []
        if let path = info.executablePath {
            mods.append(ModuleInfo(path: path, name: info.name, loadAddress: 0x1_0000_0000, size: 2 * 1024 * 1024))
        }
        let libs = ["libSystem.B.dylib", "libobjc.A.dylib", "Foundation.framework/Foundation",
                    "AppKit.framework/AppKit", "CoreFoundation.framework/CoreFoundation", "libc++.1.dylib"]
        for (i, lib) in libs.enumerated() {
            mods.append(ModuleInfo(
                path: "/usr/lib/\(lib)", name: lib,
                loadAddress: 0x7fff_0000_0000 + UInt64(i) * 0x100000,
                size: UInt64(500_000 + i * 200_000), isMappedFile: false))
        }
        return mods
    }

    func fileDescriptors(of id: ProcessID) -> [FileDescriptorInfo] {
        guard let info = processes[id] else { return [] }
        var fds: [FileDescriptorInfo] = [
            FileDescriptorInfo(id: 0, kind: .vnode, name: "/dev/null"),
            FileDescriptorInfo(id: 1, kind: .vnode, name: "/dev/null"),
            FileDescriptorInfo(id: 2, kind: .vnode, name: "/dev/null"),
        ]
        let count = min(info.fileDescriptorCount ?? 3, 40)
        for i in 3..<max(3, count) {
            let kind: FDKind = i % 4 == 0 ? .socket : (i % 3 == 0 ? .kqueue : .vnode)
            let name: String
            switch kind {
            case .socket: name = "tcp4 10.0.0.2:\(50000 + i) -> 93.184.216.34:443"
            case .kqueue: name = "kqueue"
            default:      name = "/Users/demo/Library/Caches/file\(i).dat"
            }
            fds.append(FileDescriptorInfo(id: Int32(i), kind: kind, name: name))
        }
        return fds
    }

    func sockets(of id: ProcessID) -> [SocketInfo] {
        guard processes[id] != nil else { return [] }
        let count = Int(rng.next() % 5)
        var result: [SocketInfo] = []
        for i in 0..<count {
            let fd = Int32(10 + i)
            let proto: SocketProto = i % 2 == 0 ? .tcp4 : .udp4
            let localPort = UInt16(50000 + i)
            result.append(SocketInfo(
                id: fd, proto: proto,
                localAddress: "10.0.0.2", localPort: localPort,
                remoteAddress: "93.184.216.34", remotePort: 443,
                state: i % 2 == 0 ? "ESTABLISHED" : ""))
        }
        return result
    }

    func networkRates() -> [ProcessID: UInt64] {
        var out: [ProcessID: UInt64] = [:]
        for (id, info) in processes where info.networkBytesPerSec != nil {
            out[id] = info.networkBytesPerSec
        }
        return out
    }
}

/// Small, fast, deterministic PRNG so mock output is reproducible in tests.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
