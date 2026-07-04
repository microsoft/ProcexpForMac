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
import Observation
import ProcexpModel

/// A single environment key/value pair, made `Identifiable` for `Table`.
struct EnvVar: Identifiable, Sendable, Hashable {
    let id: String        // key
    let value: String
}

@MainActor
@Observable
final class PropertiesDetail {
    // Dynamic (re-fetched on a timer while the window is open).
    var threads: [ThreadInfo] = []
    var sockets: [SocketInfo] = []
    var socketHighlights: [String: TimedListRowHighlight] = [:]

    // Static-ish (fetched once when the window opens / target changes).
    var commandLine: String?
    var currentDirectory: String?
    var environment: [EnvVar] = []
    var environmentNote: String?
    var strings: [String] = []
    var stringsNote: String?

    // Image-tab derived facts (resolved once from the on-disk image).
    var buildTime: String?
    /// Human architecture string: "x86_64", "arm64", "Universal", … or nil.
    var imageArch: String?
    /// Autostart / login-item location, resolved from `AutostartProviding`.
    var autostartLocation: String?

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

        do {
            let extracted = try await data.strings(of: pid)
            strings = extracted
            stringsNote = extracted.isEmpty ? "No printable strings were extracted from the image." : nil
        } catch {
            strings = []
            stringsNote = "Strings unavailable: \(describe(error))"
        }

        // On-disk image facts (best-effort — omitted in the UI when nil).
        if let path = record?.executablePath, !path.isEmpty {
            buildTime = Self.fileModificationDate(path).map(ByteFormat.dateTime)
            imageArch = Self.imageArchitecture(path)
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

    /// Re-fetches the live per-thread and per-socket lists.
    func refreshDynamic(
        pid: ProcessID,
        data: any ProcessDataProviding,
        network: any NetworkProviding,
        highlightDuration: TimeInterval
    ) async {
        if let updated = try? await data.threads(of: pid) { threads = updated }
        if let updated = try? await network.sockets(of: pid) { sockets = mergeSockets(updated, highlightDuration: highlightDuration) }
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
