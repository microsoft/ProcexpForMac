//
//  DetailTypes.swift
//  ProcexpModel — W0 shared contracts
//
//  Auxiliary per-selection detail types (threads, modules, descriptors,
//  sockets, signing). These are loaded lazily for the selected process.
//

import Foundation

public struct ThreadInfo: Identifiable, Sendable, Hashable {
    public var id: UInt64            // TID
    public var cpuPercent: Double
    public var cpuTime: UInt64       // nanoseconds
    public var state: String
    public var startAddress: UInt64?
    public var startSymbol: String?
    public var basePriority: Int32

    public init(
        id: UInt64,
        cpuPercent: Double = 0,
        cpuTime: UInt64 = 0,
        state: String = "",
        startAddress: UInt64? = nil,
        startSymbol: String? = nil,
        basePriority: Int32 = 0
    ) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.cpuTime = cpuTime
        self.state = state
        self.startAddress = startAddress
        self.startSymbol = startSymbol
        self.basePriority = basePriority
    }
}

/// DLL-equivalent: a dynamically mapped image (dylib / framework / mapped file).
public struct ModuleInfo: Identifiable, Sendable, Hashable {
    public var id: String            // path (unique within a process)
    public var path: String
    public var name: String
    public var loadAddress: UInt64
    public var size: UInt64
    public var signing: SignatureInfo?
    public var isMappedFile: Bool

    public init(
        path: String,
        name: String,
        loadAddress: UInt64 = 0,
        size: UInt64 = 0,
        signing: SignatureInfo? = nil,
        isMappedFile: Bool = false
    ) {
        self.id = path
        self.path = path
        self.name = name
        self.loadAddress = loadAddress
        self.size = size
        self.signing = signing
        self.isMappedFile = isMappedFile
    }
}

public enum FDKind: String, Sendable, Codable {
    case vnode
    case socket
    case pipe
    case kqueue
    case fsevent
    case machPort
    case other
}

/// Handle-equivalent: an open file descriptor (or Mach port) held by a process.
public struct FileDescriptorInfo: Identifiable, Sendable, Hashable {
    public var id: Int32             // fd number
    public var kind: FDKind
    public var name: String          // path / addr:port / description

    public init(id: Int32, kind: FDKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public enum SocketProto: String, Sendable, Codable {
    case tcp4
    case tcp6
    case udp4
    case udp6
}

public struct SocketInfo: Identifiable, Sendable, Hashable {
    public var id: Int32             // fd
    public var proto: SocketProto
    public var localAddress: String
    public var localPort: UInt16
    public var remoteAddress: String
    public var remotePort: UInt16
    public var state: String

    public init(
        id: Int32,
        proto: SocketProto,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        state: String
    ) {
        self.id = id
        self.proto = proto
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
    }
}

public struct VirusTotalResult: Sendable, Codable, Hashable {
    public var positives: Int
    public var total: Int
    public var permalink: String?
    public var checkedAt: Date

    public init(positives: Int, total: Int, permalink: String? = nil, checkedAt: Date = Date()) {
        self.positives = positives
        self.total = total
        self.permalink = permalink
        self.checkedAt = checkedAt
    }
}

public struct SignatureInfo: Sendable, Codable, Hashable {
    public var status: SigningStatus
    public var teamID: String?
    public var authority: [String]
    public var isNotarized: Bool
    public var isPlatformBinary: Bool
    public var isAdHoc: Bool
    public var sha256: String?
    public var virusTotal: VirusTotalResult?

    public init(
        status: SigningStatus = .unverified,
        teamID: String? = nil,
        authority: [String] = [],
        isNotarized: Bool = false,
        isPlatformBinary: Bool = false,
        isAdHoc: Bool = false,
        sha256: String? = nil,
        virusTotal: VirusTotalResult? = nil
    ) {
        self.status = status
        self.teamID = teamID
        self.authority = authority
        self.isNotarized = isNotarized
        self.isPlatformBinary = isPlatformBinary
        self.isAdHoc = isAdHoc
        self.sha256 = sha256
        self.virusTotal = virusTotal
    }

    /// Best single-line signer string for the "Verified Signer" column.
    public var signerDescription: String {
        switch status {
        case .unverified: return "(Verifying…)"
        case .verifying:  return "(Verifying…)"
        case .unsigned:   return "(Unsigned)"
        case .invalid:    return "(Invalid signature)"
        case .signed:
            if isPlatformBinary { return "Apple (platform)" }
            if let first = authority.first { return first }
            if let team = teamID { return "Team \(team)" }
            return isAdHoc ? "(Ad-hoc signed)" : "(Signed)"
        }
    }
}
