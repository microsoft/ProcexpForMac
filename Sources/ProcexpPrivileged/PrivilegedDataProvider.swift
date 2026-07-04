//
//  PrivilegedDataProvider.swift
//  ProcexpPrivileged — W2
//
//  The client half of the privileged path. Connects to the root helper daemon
//  over `NSXPCConnection`, and exposes it as a `PrivilegedSampling` provider so
//  the app can use it interchangeably with the unprivileged
//  `LibprocDataProvider`.
//
//  Installation is handled via `SMAppService.daemon(plistName:)`. Under the
//  current ad-hoc ("Sign to Run Locally") signature, `register()` will fail —
//  that is expected until the app is Developer-ID signed (W13). Every such
//  failure is surfaced cleanly as `ProviderError.helperUnavailable`; nothing
//  here traps.
//

import Foundation
import ServiceManagement
import ProcexpModel

/// A `PrivilegedSampling` provider backed by the root helper daemon.
///
/// `@unchecked Sendable`: the only mutable state is the cached
/// `NSXPCConnection`, guarded by `lock`. All XPC calls are reply-based and
/// funnelled through `continuation`-bridged helpers.
public final class PrivilegedDataProvider: PrivilegedSampling, @unchecked Sendable {

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    public var capabilities: ProviderCapabilities {
        [.crossUser, .accurateCPU, .threadStacks, .fullEnvironment, .modules]
    }

    // MARK: - Helper lifecycle (SMAppService)

    public static func isHelperInstalled() -> Bool {
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        // `.enabled` means launchd has it registered and will launch it on
        // demand. `.requiresApproval` counts as "installed but needs the user
        // to approve in System Settings"; treat only `.enabled` as ready.
        return service.status == .enabled
    }

    public static func installHelper() async throws {
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        do {
            try service.register()
        } catch {
            // Ad-hoc signed builds cannot register a launchd daemon; report a
            // clean, typed failure rather than propagating the raw SM error.
            throw ProviderError.helperUnavailable
        }
    }

    public static func uninstallHelper() async throws {
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        do {
            try await service.unregister()
        } catch {
            throw ProviderError.helperUnavailable
        }
    }

    // MARK: - ProcessDataProviding

    public func snapshots(interval: TimeInterval) -> AsyncStream<ProcessSnapshot> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                // First frame immediately, then poll the helper on the interval.
                continuation.yield(await self.snapshot())
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    continuation.yield(await self.snapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot snapshot. `ProcessDataProviding.snapshot()` is non-throwing, so
    /// an unreachable helper degrades to `.empty` (the app treats that as a cue
    /// to fall back to the unprivileged provider).
    public func snapshot() async -> ProcessSnapshot {
        guard let data = try? await callData({ $0.snapshot(withReply: $1) }),
              let dto = try? JSONDecoder().decode(ProcessSnapshotDTO.self, from: data)
        else { return .empty }
        return dto.model
    }

    public func threads(of id: ProcessID) async throws -> [ThreadInfo] {
        let data = try await requireData { proxy, reply in
            proxy.threads(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([ThreadInfoDTO].self, data).map(\.model)
    }

    public func modules(of id: ProcessID) async throws -> [ModuleInfo] {
        let data = try await requireData { proxy, reply in
            proxy.modules(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([ModuleInfoDTO].self, data).map(\.model)
    }

    public func fileDescriptors(of id: ProcessID) async throws -> [FileDescriptorInfo] {
        let data = try await requireData { proxy, reply in
            proxy.fileDescriptors(pid: id.pid, startTime: id.startTime, withReply: reply)
        }
        return try Self.decode([FileDescriptorInfoDTO].self, data).map(\.model)
    }

    public func commandLine(of id: ProcessID) async throws -> String? {
        try await callString { $0.commandLine(pid: id.pid, withReply: $1) }
    }

    public func environment(of id: ProcessID) async throws -> [String: String] {
        let data = try await requireData { proxy, reply in
            proxy.environment(pid: id.pid, withReply: reply)
        }
        return try Self.decode([String: String].self, data)
    }

    public func currentDirectory(of id: ProcessID) async throws -> String? {
        try await callString { $0.currentDirectory(pid: id.pid, withReply: $1) }
    }

    public func strings(of id: ProcessID) async throws -> [String] {
        let data = try await requireData { proxy, reply in
            proxy.strings(pid: id.pid, withReply: reply)
        }
        return try Self.decode([String].self, data)
    }

    // MARK: - PrivilegedSampling actions

    public func suspend(_ id: ProcessID) async throws { try await sendSignal(id, SIGSTOP) }
    public func resume(_ id: ProcessID) async throws { try await sendSignal(id, SIGCONT) }
    public func kill(_ id: ProcessID, signal: Int32) async throws { try await sendSignal(id, signal) }

    public func setNice(_ id: ProcessID, to nice: Int32) async throws {
        try await callVoid { proxy, reply in
            proxy.setNice(pid: id.pid, nice: nice, withReply: reply)
        }
    }

    private func sendSignal(_ id: ProcessID, _ sig: Int32) async throws {
        try await callVoid { proxy, reply in
            proxy.sendSignal(pid: id.pid, signal: sig, withReply: reply)
        }
    }

    // MARK: - Connection

    /// Lazily create (and cache) a connection to the helper's mach service.
    /// `.privileged` selects launchd's privileged (root) mach registration.
    private func proxyConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: ProcexpHelperProtocol.self)
        let clear: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.connection = nil; self.lock.unlock()
        }
        connection.interruptionHandler = clear
        connection.invalidationHandler = clear
        connection.resume()
        self.connection = connection
        return connection
    }

    // MARK: - Reply-block → async bridges

    /// Bridge a `(Data?, Error?)` reply block, returning the raw `Data?`.
    private func callData(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> Data? {
        let connection = proxyConnection()
        return try await withCheckedThrowingContinuation { raw in
            let box = ContinuationBox(raw)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                box.resume(throwing: ProviderError.helperUnavailable)
            }) as? ProcexpHelperProtocol else {
                box.resume(throwing: ProviderError.helperUnavailable); return
            }
            body(proxy) { data, error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: data) }
            }
        }
    }

    /// Like `callData` but treats a `nil` payload as a failure.
    private func requireData(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> Data {
        guard let data = try await callData(body) else { throw ProviderError.helperUnavailable }
        return data
    }

    /// Bridge a `(String?, Error?)` reply block. `nil` is a valid result.
    private func callString(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (String?, Error?) -> Void) -> Void
    ) async throws -> String? {
        let connection = proxyConnection()
        return try await withCheckedThrowingContinuation { raw in
            let box = ContinuationBox(raw)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                box.resume(throwing: ProviderError.helperUnavailable)
            }) as? ProcexpHelperProtocol else {
                box.resume(throwing: ProviderError.helperUnavailable); return
            }
            body(proxy) { value, error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: value) }
            }
        }
    }

    /// Bridge an `(Error?)`-only reply block.
    private func callVoid(
        _ body: @escaping (ProcexpHelperProtocol, @escaping (Error?) -> Void) -> Void
    ) async throws {
        let connection = proxyConnection()
        try await withCheckedThrowingContinuation { (raw: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(raw)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                box.resume(throwing: ProviderError.helperUnavailable)
            }) as? ProcexpHelperProtocol else {
                box.resume(throwing: ProviderError.helperUnavailable); return
            }
            body(proxy) { error in
                if let error { box.resume(throwing: Self.map(error)) }
                else { box.resume(returning: ()) }
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ProviderError.underlying("decode \(type): \(error.localizedDescription)") }
    }

    /// Map an `NSError` returned by the helper back onto a `ProviderError`.
    private static func map(_ error: Error) -> ProviderError {
        let ns = error as NSError
        guard ns.domain == HelperError.domain,
              let code = HelperError.Code(rawValue: ns.code) else {
            return .underlying(ns.localizedDescription)
        }
        switch code {
        case .notPermitted: return .notPermitted
        case .processGone:  return .processGone
        case .unsupported:  return .unsupported
        case .underlying:   return .underlying(ns.localizedDescription)
        }
    }
}

/// One-shot continuation wrapper so a stray double reply (e.g. the XPC error
/// handler firing after a normal reply, or vice versa) can never trap the
/// checked continuation.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}
