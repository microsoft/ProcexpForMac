//
//  PropertiesDetail.swift
//  W6 — Process Properties window.
//
//  Holds the asynchronously-fetched, per-process detail that backs the tabs
//  (threads, sockets, environment, strings, command line, cwd, signature).
//  The *live* `ProcessRecord`-derived values (CPU, memory, threads count, …)
//  come straight from `AppModel.snapshot` and are read in the views, so this
//  store only owns the pieces that require an `async` provider call.
//
//  One instance exists per open properties window. It is `@MainActor` +
//  `@Observable`, so mutating any stored property refreshes the SwiftUI tabs.
//

import Foundation
import Darwin
import Observation
import ProcexpModel
import Security

/// A single environment key/value pair, made `Identifiable` for `Table`.
struct EnvVar: Identifiable, Sendable, Hashable {
    let id: String        // key
    let value: String
}

struct ProcessSecurityIdentity: Sendable, Hashable {
    let effectiveUID: UInt32
    let effectiveUserName: String?
    let realUID: UInt32?
    let realUserName: String?
    let savedUID: UInt32?
    let savedUserName: String?
    let effectiveGID: UInt32?
    let effectiveGroupName: String?
    let realGID: UInt32?
    let realGroupName: String?
    let savedGID: UInt32?
    let savedGroupName: String?
    let accountPrimaryGID: UInt32?
    let accountPrimaryGroupName: String?
}

struct SecurityEntitlement: Identifiable, Sendable, Hashable {
    let key: String
    let value: String

    var id: String { key }
}

struct SecurityCodeDetails: Sendable, Hashable {
    let entitlements: [SecurityEntitlement]
    let entitlementsNote: String?
    let codeDirectoryFlags: UInt32?
    let hardenedRuntime: Bool?
    let hardenedRuntimeNote: String
    let appSandboxEntitlement: Bool?

    var codeDirectoryFlagsHex: String? {
        codeDirectoryFlags.map { String(format: "0x%08X", $0) }
    }

    static func unavailable(_ note: String) -> SecurityCodeDetails {
        SecurityCodeDetails(
            entitlements: [],
            entitlementsNote: note,
            codeDirectoryFlags: nil,
            hardenedRuntime: nil,
            hardenedRuntimeNote: note,
            appSandboxEntitlement: nil
        )
    }
}

private struct BSDCredentialSnapshot {
    let effectiveUID: UInt32
    let realUID: UInt32
    let savedUID: UInt32
    let effectiveGID: UInt32
    let realGID: UInt32
    let savedGID: UInt32
}

@MainActor
@Observable
final class PropertiesDetail {
    // Dynamic (re-fetched on a timer while the window is open).
    var threads: [ThreadInfo] = []
    var sockets: [SocketInfo] = []
    var socketRemoteNames: [String: String] = [:]
    var socketHighlights: [String: TimedListRowHighlight] = [:]
    var socketNote: String?
    private var socketRemoteNameInFlight: Set<String> = []

    // Static-ish (fetched once when the window opens / target changes).
    var commandLine: String?
    var currentDirectory: String?
    var environment: [EnvVar] = []
    var environmentNote: String?
    var strings: [String] = []
    var stringsNote: String?
    var isLoadingStrings = false
    private var stringsLoaded = false

    // Image-tab derived facts (resolved once from the on-disk image).
    var buildTime: String?
    /// Human architecture string: "x86_64", "arm64", "Universal", … or nil.
    var imageArch: String?
    /// Autostart / login-item location, resolved from `AutostartProviding`.
    var autostartLocation: String?

    // Security tab derived facts (resolved once from process credentials / image).
    var securityIdentity: ProcessSecurityIdentity?
    var securityCode: SecurityCodeDetails?

    // Signing / reputation.
    var signature: SignatureInfo?
    var isVerifying = false
    var isCheckingVirusTotal = false
    var virusTotalNote: String?

    // MARK: - Per-process history (Performance Graph tab)
    //
    // Small rings (~120 samples ≈ 2 min at 1 Hz) appended one value per
    // snapshot tick while this window is open. Mirrors Procexp's per-process
    // graph tab, which only starts drawing once the Properties window opens.
    var cpuRing = HistoryRing<Double>(capacity: 120)       // percent (100 == 1 core)
    var privateRing = HistoryRing<Double>(capacity: 120)   // bytes
    var ioRing = HistoryRing<Double>(capacity: 120)        // bytes / second

    /// Page-fault delta since the previous sample (Performance tab).
    var pageFaultDelta: UInt64 = 0

    // Rate/delta bookkeeping.
    private var lastIOBytes: UInt64?
    private var lastIOTime: Date?
    private var lastPageFaults: UInt64?
    private var lastSampleTimestamp: Date?

    /// Loads the values that don't change second-to-second. Best-effort: any
    /// permission-limited call degrades to an empty result plus a note.
    func loadStatic(
        pid: ProcessID,
        record: ProcessRecord?,
        data: any ProcessDataProviding,
        signing: any SigningProviding,
        autostart: any AutostartProviding
    ) async {
        strings = []
        stringsNote = nil
        stringsLoaded = false
        isLoadingStrings = false

        if let record {
            securityIdentity = Self.securityIdentity(pid: pid, record: record)
        } else {
            securityIdentity = nil
            securityCode = nil
        }

        commandLine = (try? await data.commandLine(of: pid)) ?? nil
        currentDirectory = (try? await data.currentDirectory(of: pid)) ?? nil

        do {
            let env = try await data.environment(of: pid)
            environment = env
                .map { EnvVar(id: $0.key, value: $0.value) }
                .sorted { $0.id.lowercased() < $1.id.lowercased() }
            environmentNote = env.isEmpty
                ? "No environment variables were returned. macOS only exposes the environment of processes owned by the current user; other processes require the privileged helper."
                : nil
        } catch {
            environment = []
            environmentNote = "Environment unavailable: \(describe(error))"
        }

        // On-disk image facts (best-effort — omitted in the UI when nil).
        if let path = record?.executablePath, !path.isEmpty {
            buildTime = Self.fileModificationDate(path).map(ByteFormat.dateTime)
            imageArch = Self.imageArchitecture(path)
            securityCode = Self.securityCodeDetails(path: path)
        } else {
            securityCode = .unavailable("No executable path was reported for this process.")
        }

        // Autostart location. Prefer the value already resolved on the record
        // (if the sampler filled it), otherwise ask the provider.
        if let record {
            if let loc = record.autostartLocation, !loc.isEmpty {
                autostartLocation = loc
            } else {
                autostartLocation = await autostart.autostartLocation(for: record)
            }
        }

        if let path = record?.executablePath, !path.isEmpty {
            await verifySignature(path: path, signing: signing)
        }
    }

    func loadStringsIfNeeded(pid: ProcessID, data: any ProcessDataProviding) async {
        guard !stringsLoaded, !isLoadingStrings else { return }
        isLoadingStrings = true
        stringsNote = nil
        defer {
            isLoadingStrings = false
            stringsLoaded = true
        }
        do {
            let extracted = try await data.strings(of: pid)
            strings = extracted
            stringsNote = extracted.isEmpty ? "No printable strings were extracted from the image." : nil
        } catch {
            strings = []
            stringsNote = "Strings unavailable: \(describe(error))"
        }
    }

    /// Re-fetches the live per-thread and per-socket lists.
    func refreshDynamic(
        pid: ProcessID,
        record: ProcessRecord?,
        data: any ProcessDataProviding,
        network: any NetworkProviding,
        highlightDuration: TimeInterval
    ) async {
        if let updated = try? await data.threads(of: pid) { threads = updated }
        do {
            let updated = try await network.sockets(of: pid)
            sockets = mergeSockets(updated, highlightDuration: highlightDuration)
            scheduleRemoteNameLookups(for: sockets)
            socketNote = updated.isEmpty ? Self.emptySocketsNote(record: record, data: data) : nil
        } catch {
            sockets = []
            socketNote = "TCP/IP sockets unavailable: \(describe(error))"
        }
    }

    private static func emptySocketsNote(record: ProcessRecord?, data: any ProcessDataProviding) -> String {
        let base = "No TCP/IP sockets were returned."
        let providerHasCrossUserVisibility = data.capabilities.contains(.crossUser)
        guard let record else {
            return "\(base) The process may have exited, or macOS returned no socket details."
        }

        let otherUser = !record.flags.contains(.ownProcess)
        let protected = record.uid == 0
            || record.flags.contains(.platformBinary)
            || record.flags.contains(.service)

        if otherUser || protected || !providerHasCrossUserVisibility {
            return "\(base) macOS may refuse socket enumeration for protected or other-user processes, so this is not proof the process has no network sockets."
        }
        return "\(base) This can mean the process has no TCP/IP sockets, the process exited, or macOS returned no socket details."
    }

    private func mergeSockets(_ incoming: [SocketInfo], highlightDuration: TimeInterval) -> [SocketInfo] {
        let now = Date()
        let expiry = now.addingTimeInterval(max(0.2, highlightDuration))
        let oldByID = Dictionary(uniqueKeysWithValues: sockets.map { (socketKey($0), $0) })
        let newByID = Dictionary(uniqueKeysWithValues: incoming.map { (socketKey($0), $0) })
        let oldIDs = Set(oldByID.keys)
        let newIDs = Set(newByID.keys)
        socketHighlights = socketHighlights.filter { $0.value.expiresAt > now }
        if oldByID.isEmpty && socketHighlights.isEmpty { return incoming }
        for id in newIDs.subtracting(oldIDs) {
            socketHighlights[id] = TimedListRowHighlight(kind: .new, expiresAt: expiry)
        }
        for id in oldIDs.subtracting(newIDs) {
            socketHighlights[id] = TimedListRowHighlight(kind: .deleted, expiresAt: expiry)
        }
        let deletedRows = oldByID.values.filter { socketHighlights[socketKey($0)]?.kind == .deleted }
        return incoming + deletedRows
    }

    private func socketKey(_ socket: SocketInfo) -> String {
        "\(socket.id)|\(socket.proto.rawValue)|\(socket.localAddress)|\(socket.localPort)|\(socket.remoteAddress)|\(socket.remotePort)|\(socket.state)"
    }

    private func scheduleRemoteNameLookups(for sockets: [SocketInfo]) {
        for socket in sockets {
            let key = socketKey(socket)
            guard socket.remotePort != 0,
                  !socket.remoteAddress.isEmpty,
                  socket.remoteAddress != "*",
                  socket.remoteAddress != "0.0.0.0",
                  socket.remoteAddress != "::",
                  socketRemoteNames[key] == nil,
                  !socketRemoteNameInFlight.contains(key) else { continue }
            socketRemoteNameInFlight.insert(key)
            let address = socket.remoteAddress
            Task { @MainActor in
                let name = await Self.reverseDNSName(for: address) ?? ""
                socketRemoteNames[key] = name
                socketRemoteNameInFlight.remove(key)
            }
        }
    }

    nonisolated private static func reverseDNSName(for address: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: reverseDNSNameSync(for: address))
            }
        }
    }

    nonisolated private static func reverseDNSNameSync(for address: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if address.contains(":") {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            let parsed = withUnsafeMutablePointer(to: &addr6.sin6_addr) { addrPtr in
                inet_pton(AF_INET6, address, addrPtr)
            }
            guard parsed == 1 else { return nil }
            let status = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPtr in
                    getnameinfo(addressPtr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
            return status == 0 ? String(cString: host) : nil
        }

        var addr4 = sockaddr_in()
        addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr4.sin_family = sa_family_t(AF_INET)
        let parsed = withUnsafeMutablePointer(to: &addr4.sin_addr) { addrPtr in
            inet_pton(AF_INET, address, addrPtr)
        }
        guard parsed == 1 else { return nil }
        let status = withUnsafePointer(to: &addr4) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPtr in
                getnameinfo(addressPtr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return status == 0 ? String(cString: host) : nil
    }

    /// Appends one sample to the per-process history rings and recomputes the
    /// page-fault delta. Called once per snapshot tick while the window is
    /// open. De-duplicates on the snapshot timestamp so a re-render can't
    /// double-append.
    func appendHistory(record: ProcessRecord, at timestamp: Date) {
        if let last = lastSampleTimestamp, last == timestamp { return }
        lastSampleTimestamp = timestamp

        cpuRing.append(record.cpuPercent)
        privateRing.append(Double(record.physFootprint ?? record.residentSize))

        // I/O throughput = Δ(read + write) / Δt.
        let ioTotal = (record.diskBytesRead ?? 0) + (record.diskBytesWritten ?? 0)
        if let lastBytes = lastIOBytes, let lastTime = lastIOTime {
            let dt = timestamp.timeIntervalSince(lastTime)
            if dt > 0 && ioTotal >= lastBytes {
                ioRing.append(Double(ioTotal - lastBytes) / dt)
            } else {
                ioRing.append(0)
            }
        } else {
            ioRing.append(0)
        }
        lastIOBytes = ioTotal
        lastIOTime = timestamp

        // Page-fault delta.
        if let pf = record.pageFaults {
            if let lastPF = lastPageFaults {
                pageFaultDelta = pf >= lastPF ? pf - lastPF : 0
            }
            lastPageFaults = pf
        }
    }

    /// Runs a fresh code-signature verification for the image path.
    func verifySignature(path: String, signing: any SigningProviding) async {
        isVerifying = true
        let existingVT = signature?.virusTotal
        var result = await signing.signature(forPath: path)
        // Preserve any VirusTotal result the user already fetched.
        if result.virusTotal == nil { result.virusTotal = existingVT }
        signature = result
        isVerifying = false
    }

    /// Looks up the current image's SHA-256 on VirusTotal (best-effort).
    func checkVirusTotal(signing: any SigningProviding) async {
        guard let sha = signature?.sha256, !sha.isEmpty else {
            virusTotalNote = "No SHA-256 is available to look up. Verify the signature first."
            return
        }
        isCheckingVirusTotal = true
        virusTotalNote = nil
        defer { isCheckingVirusTotal = false }
        do {
            if let vt = try await signing.virusTotal(sha256: sha) {
                signature?.virusTotal = vt
            } else {
                virusTotalNote = "No VirusTotal result (no API key configured, or the file is unknown to VirusTotal)."
            }
        } catch {
            virusTotalNote = "VirusTotal lookup failed: \(describe(error))"
        }
    }

    /// Whether a VirusTotal lookup is even possible right now.
    var canCheckVirusTotal: Bool {
        !(signature?.sha256 ?? "").isEmpty && !isCheckingVirusTotal
    }

    // MARK: - On-disk image helpers

    private static func securityIdentity(pid: ProcessID, record: ProcessRecord) -> ProcessSecurityIdentity {
        let bsd = processCredential(pid: pid.pid)
        let effectiveUID = bsd?.effectiveUID ?? record.uid
        let account = passwd(uid: record.uid)
        let accountPrimaryGID = account?.primaryGID

        return ProcessSecurityIdentity(
            effectiveUID: effectiveUID,
            effectiveUserName: record.userName ?? userName(uid: effectiveUID),
            realUID: bsd?.realUID,
            realUserName: bsd.flatMap { userName(uid: $0.realUID) },
            savedUID: bsd?.savedUID,
            savedUserName: bsd.flatMap { userName(uid: $0.savedUID) },
            effectiveGID: bsd?.effectiveGID,
            effectiveGroupName: bsd.flatMap { groupName(gid: $0.effectiveGID) },
            realGID: bsd?.realGID,
            realGroupName: bsd.flatMap { groupName(gid: $0.realGID) },
            savedGID: bsd?.savedGID,
            savedGroupName: bsd.flatMap { groupName(gid: $0.savedGID) },
            accountPrimaryGID: accountPrimaryGID,
            accountPrimaryGroupName: accountPrimaryGID.flatMap(groupName)
        )
    }

    private static func processCredential(pid: Int32) -> BSDCredentialSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        return BSDCredentialSnapshot(
            effectiveUID: UInt32(info.pbi_uid),
            realUID: UInt32(info.pbi_ruid),
            savedUID: UInt32(info.pbi_svuid),
            effectiveGID: UInt32(info.pbi_gid),
            realGID: UInt32(info.pbi_rgid),
            savedGID: UInt32(info.pbi_svgid)
        )
    }

    private static func passwd(uid: UInt32) -> (name: String, primaryGID: UInt32)? {
        guard let entry = getpwuid(uid_t(uid)) else { return nil }
        return (String(cString: entry.pointee.pw_name), UInt32(entry.pointee.pw_gid))
    }

    private static func userName(uid: UInt32) -> String? {
        passwd(uid: uid)?.name
    }

    private static func groupName(gid: UInt32) -> String? {
        guard let entry = getgrgid(gid_t(gid)) else { return nil }
        return String(cString: entry.pointee.gr_name)
    }

    private static func securityCodeDetails(path: String) -> SecurityCodeDetails {
        let url = URL(fileURLWithPath: path)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .unavailable("Code-signing metadata unavailable: \(securityError(createStatus)).")
        }

        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation))
        var infoCF: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(code, flags, &infoCF)
        guard copyStatus == errSecSuccess, let infoCF else {
            return .unavailable("Code-signing metadata unavailable: \(securityError(copyStatus)).")
        }

        let info = infoCF as NSDictionary
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let runtimeBit: UInt32 = 0x0001_0000
        let hardenedRuntime = codeFlags.map { ($0 & runtimeBit) != 0 }
        let hardenedRuntimeNote: String
        if hardenedRuntime == true {
            hardenedRuntimeNote = "Best-effort: detected from the code-signing runtime flag."
        } else if hardenedRuntime == false {
            hardenedRuntimeNote = "Best-effort: no hardened-runtime flag was found in the code signature."
        } else {
            hardenedRuntimeNote = "Best-effort: code-directory flags were not returned."
        }

        let entitlementsDict = info[kSecCodeInfoEntitlementsDict as String] as? NSDictionary
        let entitlements = entitlementsDict.map(formatEntitlements) ?? []
        let entitlementsNote: String?
        if entitlementsDict == nil {
            entitlementsNote = "No entitlements dictionary was returned for this image."
        } else if entitlements.isEmpty {
            entitlementsNote = "The image has an empty entitlements dictionary."
        } else {
            entitlementsNote = nil
        }

        return SecurityCodeDetails(
            entitlements: entitlements,
            entitlementsNote: entitlementsNote,
            codeDirectoryFlags: codeFlags,
            hardenedRuntime: hardenedRuntime,
            hardenedRuntimeNote: hardenedRuntimeNote,
            appSandboxEntitlement: entitlementsDict.flatMap {
                entitlementBool($0, key: "com.apple.security.app-sandbox")
            }
        )
    }

    private static func formatEntitlements(_ dict: NSDictionary) -> [SecurityEntitlement] {
        dict.allKeys
            .compactMap { $0 as? String }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { key in
                SecurityEntitlement(key: key, value: formatPlistValue(dict[key] ?? ""))
            }
    }

    private static func entitlementBool(_ dict: NSDictionary, key: String) -> Bool? {
        guard let value = dict[key] else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func formatPlistValue(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let date = value as? Date { return ByteFormat.dateTime(date) }
        if let data = value as? Data { return "<\(data.count) bytes>" }
        if let array = value as? [Any] {
            return "[" + array.map(formatPlistValue).joined(separator: ", ") + "]"
        }
        if let dict = value as? NSDictionary {
            let parts = dict.allKeys
                .compactMap { $0 as? String }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { key in "\(key): \(formatPlistValue(dict[key] ?? ""))" }
            return "{" + parts.joined(separator: ", ") + "}"
        }
        return String(describing: value)
    }

    private static func securityError(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "OSStatus \(status)"
    }

    private static func fileModificationDate(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// Reads the Mach-O magic + cputype to classify the image architecture.
    /// Returns nil when the file can't be read or isn't a recognised binary.
    private static func imageArchitecture(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count >= 8 else { return nil }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Fat / universal binary.
        let fatMagic: UInt32 = 0xcafe_babe
        let fatCigam: UInt32 = 0xbeba_feca
        if magic == fatMagic || magic == fatCigam { return "Universal" }

        // Thin Mach-O: cputype follows the 32-bit magic.
        let mhMagic64: UInt32 = 0xfeed_facf
        let mhCigam64: UInt32 = 0xcffa_edfe
        let mhMagic: UInt32   = 0xfeed_face
        let mhCigam: UInt32   = 0xcefa_edfe
        let swapped = (magic == mhCigam64 || magic == mhCigam)
        guard magic == mhMagic64 || magic == mhCigam64 || magic == mhMagic || magic == mhCigam else {
            return nil
        }

        var cputype = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        if swapped { cputype = Int32(bitPattern: UInt32(bitPattern: cputype).byteSwapped) }

        switch cputype {
        case 0x0100_0007: return "x86_64"
        case 0x0100_000C: return "arm64"
        case 7:           return "i386"
        case 12:          return "arm"
        default:          return nil
        }
    }
}

/// Short, human-readable description of a provider error.
private func describe(_ error: Error) -> String {
    if let providerError = error as? ProviderError {
        switch providerError {
        case .notPermitted:      return "operation not permitted"
        case .processGone:       return "the process has exited"
        case .unsupported:       return "not supported on this system"
        case .helperUnavailable: return "the privileged helper is not installed"
        case .underlying(let message): return message
        }
    }
    return error.localizedDescription
}
