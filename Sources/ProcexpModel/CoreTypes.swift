//
//  CoreTypes.swift
//  ProcexpModel — W0 shared contracts
//
//  Core identity and per-process value types. All types are immutable value
//  types and Sendable so snapshots can cross actor/thread boundaries freely.
//

import Foundation

/// Stable identity for a process across refreshes.
///
/// PIDs are reused by the OS, so identity is the pair `(pid, startTime)`.
/// All diffing (new/dead highlighting, tree stability) keys on this.
public struct ProcessID: Hashable, Sendable, Codable {
    public let pid: Int32
    /// Process start time expressed as whole seconds since the UNIX epoch.
    /// Used only to disambiguate reused PIDs — not for display.
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

extension ProcessID: CustomStringConvertible {
    public var description: String { "pid \(pid)@\(startTime)" }
}

public enum SigningStatus: String, Sendable, Codable {
    case unverified
    case verifying
    case signed
    case unsigned
    case invalid
}

public enum ImageType: String, Sendable, Codable {
    case appBundle
    case cli
    case daemon
    case xpc
    case unknown
}

/// Bit flags that drive row coloring, badges, and filtering.
public struct ProcessFlags: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Belongs to the current user's session / the ProcexpMac app family.
    public static let ownProcess     = ProcessFlags(rawValue: 1 << 0)
    /// Managed by launchd (daemon/agent) — analog of a Windows service.
    public static let service        = ProcessFlags(rawValue: 1 << 1)
    public static let suspended      = ProcessFlags(rawValue: 1 << 2)
    /// App Sandbox in effect — analog of Windows "immersive"/AppContainer.
    public static let sandboxed      = ProcessFlags(rawValue: 1 << 3)
    public static let platformBinary = ProcessFlags(rawValue: 1 << 4)
    /// Heuristically "packed"/obfuscated image.
    public static let packed         = ProcessFlags(rawValue: 1 << 5)
    /// Appeared since the previous snapshot (green fade).
    public static let newProcess     = ProcessFlags(rawValue: 1 << 6)
    /// Disappeared since the previous snapshot (red fade).
    public static let deadProcess    = ProcessFlags(rawValue: 1 << 7)
}

/// One process sampled at one instant. Immutable snapshot element.
public struct ProcessRecord: Identifiable, Sendable, Hashable {
    public var id: ProcessID
    public var parent: ProcessID?
    public var name: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var iconPath: String?
    public var imageType: ImageType

    // Ownership
    public var uid: UInt32
    public var userName: String?
    public var sessionTTY: String?

    // Descriptive
    public var displayDescription: String?
    public var companyName: String?
    public var version: String?

    // CPU
    /// Instantaneous CPU usage. Normalized so that 100.0 == one fully-busy core.
    /// A process using two cores reads ~200.0. (Matches Activity Monitor semantics.)
    public var cpuPercent: Double
    /// Cumulative user+system CPU time in nanoseconds.
    public var cpuTime: UInt64
    public var threadCount: Int
    public var contextSwitches: UInt64?

    // Memory (bytes)
    public var residentSize: UInt64
    public var virtualSize: UInt64
    public var physFootprint: UInt64?
    public var pageFaults: UInt64?

    // I/O (cumulative bytes)
    public var diskBytesRead: UInt64?
    public var diskBytesWritten: UInt64?

    // Handles-equivalent
    public var fileDescriptorCount: Int?

    // Scheduling
    public var nice: Int32
    public var priority: Int32

    // Coloring / badges
    public var flags: ProcessFlags

    // Filled asynchronously by other providers
    public var signing: SignatureInfo?
    public var networkBytesPerSec: UInt64?
    public var gpuPercent: Double?
    public var autostartLocation: String?

    public var startTimeDate: Date

    public init(
        id: ProcessID,
        parent: ProcessID? = nil,
        name: String,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        iconPath: String? = nil,
        imageType: ImageType = .unknown,
        uid: UInt32 = 0,
        userName: String? = nil,
        sessionTTY: String? = nil,
        displayDescription: String? = nil,
        companyName: String? = nil,
        version: String? = nil,
        cpuPercent: Double = 0,
        cpuTime: UInt64 = 0,
        threadCount: Int = 0,
        contextSwitches: UInt64? = nil,
        residentSize: UInt64 = 0,
        virtualSize: UInt64 = 0,
        physFootprint: UInt64? = nil,
        pageFaults: UInt64? = nil,
        diskBytesRead: UInt64? = nil,
        diskBytesWritten: UInt64? = nil,
        fileDescriptorCount: Int? = nil,
        nice: Int32 = 0,
        priority: Int32 = 0,
        flags: ProcessFlags = [],
        signing: SignatureInfo? = nil,
        networkBytesPerSec: UInt64? = nil,
        gpuPercent: Double? = nil,
        autostartLocation: String? = nil,
        startTimeDate: Date = .distantPast
    ) {
        self.id = id
        self.parent = parent
        self.name = name
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.iconPath = iconPath
        self.imageType = imageType
        self.uid = uid
        self.userName = userName
        self.sessionTTY = sessionTTY
        self.displayDescription = displayDescription
        self.companyName = companyName
        self.version = version
        self.cpuPercent = cpuPercent
        self.cpuTime = cpuTime
        self.threadCount = threadCount
        self.contextSwitches = contextSwitches
        self.residentSize = residentSize
        self.virtualSize = virtualSize
        self.physFootprint = physFootprint
        self.pageFaults = pageFaults
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.fileDescriptorCount = fileDescriptorCount
        self.nice = nice
        self.priority = priority
        self.flags = flags
        self.signing = signing
        self.networkBytesPerSec = networkBytesPerSec
        self.gpuPercent = gpuPercent
        self.autostartLocation = autostartLocation
        self.startTimeDate = startTimeDate
    }
}
