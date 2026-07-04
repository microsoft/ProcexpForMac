# Shared Data Contracts (W0 — `ProcexpModel`)

These are the **frozen interfaces** every workstream builds against. Treat changes here as
breaking — coordinate before editing.

> Swift shown is the **intended shape**; W0's owner finalizes exact types. Keep value types
> `Sendable` and (where noted) `Codable`.

---

## 1. Identity & core value types

```swift
/// Stable identity across refreshes (survives PID reuse).
public struct ProcessID: Hashable, Sendable, Codable {
    public let pid: Int32
    public let startTime: UInt64   // mach abs or unix nanos; used only for identity
}

public enum SigningStatus: Sendable, Codable {
    case unverified, verifying, signed, unsigned, invalid
}

public enum ImageType: Sendable, Codable { case appBundle, cli, daemon, xpc, unknown }

/// One process at one sample instant. Immutable.
public struct ProcessRecord: Identifiable, Sendable {
    public var id: ProcessID
    public var parent: ProcessID?
    public var name: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var iconPath: String?          // path used to resolve NSWorkspace icon

    // Ownership
    public var uid: uid_t
    public var userName: String?
    public var sessionTTY: String?

    // Descriptive (from bundle / signing)
    public var displayDescription: String?
    public var companyName: String?
    public var version: String?

    // CPU
    public var cpuPercent: Double         // 0...(100*ncpu) or normalized — document choice
    public var cpuTime: UInt64            // total user+system, nanos
    public var threadCount: Int
    public var contextSwitches: UInt64?

    // Memory (bytes)
    public var residentSize: UInt64
    public var virtualSize: UInt64
    public var physFootprint: UInt64?     // privileged/own
    public var pageFaults: UInt64?

    // I/O (bytes, cumulative)
    public var diskBytesRead: UInt64?
    public var diskBytesWritten: UInt64?

    // Handles-equivalent
    public var fileDescriptorCount: Int?

    // Scheduling
    public var nice: Int32
    public var priority: Int32

    // Flags used for coloring / badges
    public var flags: ProcessFlags

    // Signing / security (filled asynchronously by W7)
    public var signing: SignatureInfo?

    // Network / GPU (filled by W9, optional)
    public var networkBytesPerSec: UInt64?
    public var gpuPercent: Double?

    // Autostart (W12)
    public var autostartLocation: String?

    public var startTimeDate: Date
}

public struct ProcessFlags: OptionSet, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let ownProcess    = ProcessFlags(rawValue: 1 << 0)
    public static let service       = ProcessFlags(rawValue: 1 << 1) // launchd-managed
    public static let suspended     = ProcessFlags(rawValue: 1 << 2)
    public static let sandboxed     = ProcessFlags(rawValue: 1 << 3) // ~ "immersive"
    public static let platformBinary = ProcessFlags(rawValue: 1 << 4)
    public static let packed        = ProcessFlags(rawValue: 1 << 5) // heuristic
    public static let newProcess    = ProcessFlags(rawValue: 1 << 6) // diff highlight
    public static let deadProcess   = ProcessFlags(rawValue: 1 << 7) // diff highlight
}
```

## 2. Snapshot & diffing

```swift
/// The whole world at one instant. UI renders from this.
public struct ProcessSnapshot: Sendable {
    public let timestamp: Date
    public let interval: TimeInterval
    public let processes: [ProcessID: ProcessRecord]
    public let roots: [ProcessID]                 // top of tree (ppid == launchd/0)
    public let children: [ProcessID: [ProcessID]] // adjacency for the tree
    public let system: SystemStats
}
```

Diff highlighting: W3 compares consecutive snapshots by `ProcessID`. Newly appeared →
`.newProcess`; disappeared → keep one fading frame flagged `.deadProcess`.

## 3. Auxiliary detail types (lazy-loaded per selection)

```swift
public struct ThreadInfo: Identifiable, Sendable {
    public var id: UInt64          // TID
    public var cpuPercent: Double
    public var cpuTime: UInt64
    public var state: String       // running/waiting/…
    public var startAddress: UInt64?
    public var startSymbol: String?
    public var basePriority: Int32
}

public struct ModuleInfo: Identifiable, Sendable {          // DLL-equivalent (mapped image)
    public var id: String          // path
    public var path: String
    public var name: String
    public var loadAddress: UInt64
    public var size: UInt64
    public var signing: SignatureInfo?
    public var isMappedFile: Bool
}

public struct FileDescriptorInfo: Identifiable, Sendable {  // handle-equivalent
    public var id: Int32           // fd number
    public var kind: FDKind        // .vnode/.socket/.pipe/.kqueue/.machPort/…
    public var name: String        // path / addr:port / description
}
public enum FDKind: String, Sendable, Codable { case vnode, socket, pipe, kqueue, fsevent, machPort, other }

public struct SocketInfo: Identifiable, Sendable {
    public var id: Int32           // fd
    public var proto: SocketProto  // tcp/udp v4/v6
    public var localAddress: String
    public var localPort: UInt16
    public var remoteAddress: String
    public var remotePort: UInt16
    public var state: String       // ESTABLISHED/LISTEN/…
}
public enum SocketProto: String, Sendable, Codable { case tcp4, tcp6, udp4, udp6 }

public struct SignatureInfo: Sendable, Codable {
    public var status: SigningStatus
    public var teamID: String?
    public var authority: [String]     // cert chain CN(s)
    public var isNotarized: Bool
    public var isPlatformBinary: Bool
    public var isAdHoc: Bool
    public var sha256: String?
    public var virusTotal: VirusTotalResult?
}

public struct VirusTotalResult: Sendable, Codable {
    public var positives: Int
    public var total: Int
    public var permalink: String?
    public var checkedAt: Date
}
```

## 4. System stats & history

```swift
public struct SystemStats: Sendable {
    public var cpuTotalPercent: Double
    public var perCoreCPUPercent: [Double]
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryWired: UInt64
    public var memoryCompressed: UInt64
    public var swapUsed: UInt64
    public var diskBytesPerSec: UInt64
    public var networkBytesPerSec: UInt64
    public var gpuPercent: Double?
    public var processCount: Int
    public var threadCount: Int
    public var handleCount: Int      // total fds
}

/// Fixed-capacity ring buffer for graph history.
public struct HistoryRing<Element: Sendable>: Sendable {
    public init(capacity: Int)
    public mutating func append(_ value: Element)
    public var values: [Element] { get }   // oldest → newest
    public var capacity: Int { get }
}
```

## 5. Columns

```swift
public enum Column: String, CaseIterable, Sendable, Codable {
    case name, pid, ppid, cpu, cpuTime, privateBytes, workingSet, virtualSize,
         threads, handles, description, company, version, path, commandLine,
         user, session, startTime, priority, nice, ioRead, ioWrite,
         network, gpu, gpuMemory, integrity, signature, virusTotal, autostart
    public var title: String { … }
    public var defaultWidth: CGFloat { … }
    public var isRightAligned: Bool { … }
    /// Formats a cell value for a given process (pure function).
    public func string(for p: ProcessRecord) -> String { … }
    public func sortValue(for p: ProcessRecord) -> SortKey { … }
}
```

## 6. Coloring rules

```swift
public struct ProcessColorRule: Sendable, Codable {
    public var flag: ProcessFlags
    public var isEnabled: Bool
    public var backgroundLight: RGBA
    public var backgroundDark: RGBA
}
// Defaults mirror Procexp: own=lightblue, service=pink, suspended=gray,
// new=green(fade), dead=red(fade), packed=purple, sandboxed=cyan.
```

## 7. Provider protocols (the seams for parallel work)

```swift
/// Primary source of process snapshots. W1 (unprivileged) & W2 (privileged) both conform;
/// UI depends only on this.
public protocol ProcessDataProviding: Sendable {
    /// Async stream of snapshots at the configured refresh interval.
    func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot>
    func threads(of id: ProcessID) async throws -> [ThreadInfo]
    func modules(of id: ProcessID) async throws -> [ModuleInfo]
    func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo]
    func commandLine(of id: ProcessID) async throws -> String?
    func environment(of id: ProcessID) async throws -> [String: String]
    func currentDirectory(of id: ProcessID) async throws -> String?
    func strings(of id: ProcessID) async throws -> [String]
    var capabilities: ProviderCapabilities { get }
}

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32; public init(rawValue: UInt32){self.rawValue=rawValue}
    public static let crossUser      = ProviderCapabilities(rawValue: 1<<0)
    public static let accurateCPU    = ProviderCapabilities(rawValue: 1<<1)
    public static let threadStacks   = ProviderCapabilities(rawValue: 1<<2)
    public static let fullEnvironment = ProviderCapabilities(rawValue: 1<<3)
}

/// Root helper client (W2). Wraps XPC. Optional at runtime.
public protocol PrivilegedSampling: ProcessDataProviding {
    static func isHelperInstalled() -> Bool
    static func installHelper() async throws
    static func uninstallHelper() async throws
    func suspend(_ id: ProcessID) async throws
    func resume(_ id: ProcessID) async throws
    func setNice(_ id: ProcessID, to nice: Int32) async throws
    func kill(_ id: ProcessID, signal: Int32) async throws
}

public protocol SigningProviding: Sendable {                 // W7
    func signature(forPath path: String) async -> SignatureInfo
    func virusTotal(sha256: String) async throws -> VirusTotalResult?
}

public protocol NetworkProviding: Sendable {                 // W9
    func sockets(of id: ProcessID) async throws -> [SocketInfo]
    func networkRates() async -> [ProcessID: UInt64]
}

public protocol SystemStatsProviding: Sendable {             // W4
    func stats() async -> SystemStats
}

public protocol AutostartProviding: Sendable {               // W12
    func autostartLocation(for p: ProcessRecord) async -> String?
}
```

## 8. App-level observable state (owned by App target, referenced by contracts)

```swift
@Observable public final class AppModel {
    public var snapshot: ProcessSnapshot
    public var selection: ProcessID?
    public var refreshInterval: TimeInterval
    public var columns: [Column]
    public var colorRules: [ProcessColorRule]
    public var lowerPaneMode: LowerPaneMode   // .modules / .descriptors / .hidden
    public var history: SystemHistory          // rings for CPU/mem/io/net/gpu
    // injected providers:
    public let data: any ProcessDataProviding
    public let signing: any SigningProviding
    public let network: any NetworkProviding
    public let system: any SystemStatsProviding
}
```
