//
//  Providers.swift
//  ProcexpModel — W0 shared contracts
//
//  The provider protocols are the seams that let workstreams develop in
//  parallel. UI depends only on these; W1 (unprivileged) and W2 (privileged)
//  both conform to `ProcessDataProviding`.
//

import Foundation

/// Capabilities a provider may or may not offer, so the UI can degrade gracefully.
public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let crossUser       = ProviderCapabilities(rawValue: 1 << 0)
    public static let accurateCPU     = ProviderCapabilities(rawValue: 1 << 1)
    public static let threadStacks    = ProviderCapabilities(rawValue: 1 << 2)
    public static let fullEnvironment = ProviderCapabilities(rawValue: 1 << 3)
    public static let modules         = ProviderCapabilities(rawValue: 1 << 4)
}

/// Primary source of process snapshots. The UI observes `snapshots(interval:)`.
public protocol ProcessDataProviding: Sendable {
    /// An async stream of snapshots produced at approximately `interval` seconds.
    func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot>

    /// A one-shot snapshot (used for tests and initial paint).
    func snapshot() async -> ProcessSnapshot

    func threads(of id: ProcessID) async throws -> [ThreadInfo]
    func modules(of id: ProcessID) async throws -> [ModuleInfo]
    func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo]
    func commandLine(of id: ProcessID) async throws -> String?
    func environment(of id: ProcessID) async throws -> [String: String]
    func currentDirectory(of id: ProcessID) async throws -> String?
    func strings(of id: ProcessID) async throws -> [String]

    var capabilities: ProviderCapabilities { get }
}

/// Errors providers may throw. Kept minimal and Sendable.
public enum ProviderError: Error, Sendable {
    case notPermitted
    case processGone
    case unsupported
    case helperUnavailable
    case underlying(String)
}

/// Root-helper client (W2) — a privileged `ProcessDataProviding` that can also
/// perform control actions. Optional at runtime.
public protocol PrivilegedSampling: ProcessDataProviding {
    static func isHelperInstalled() -> Bool
    static func installHelper() async throws
    static func uninstallHelper() async throws

    func suspend(_ id: ProcessID) async throws
    func resume(_ id: ProcessID) async throws
    func setNice(_ id: ProcessID, to nice: Int32) async throws
    func kill(_ id: ProcessID, signal: Int32) async throws
}

/// Code signing + reputation (W7).
public protocol SigningProviding: Sendable {
    func signature(forPath path: String) async -> SignatureInfo
    func virusTotal(sha256: String) async throws -> VirusTotalResult?
}

/// Per-process networking (W9).
public protocol NetworkProviding: Sendable {
    func sockets(of id: ProcessID) async throws -> [SocketInfo]
    func networkRates() async -> [ProcessID: UInt64]
}

/// System-wide stats source (W4).
public protocol SystemStatsProviding: Sendable {
    func stats() async -> SystemStats
}

/// Autostart source resolution (W12).
public protocol AutostartProviding: Sendable {
    func autostartLocation(for process: ProcessRecord) async -> String?
}
