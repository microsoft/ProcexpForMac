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
    public var name: String
    public var cpuPercent: Double
    public var cpuTime: UInt64       // nanoseconds
    public var state: String
    public var startAddress: UInt64?
    public var startSymbol: String?
    public var currentPriority: Int32
    public var basePriority: Int32
    public var maxPriority: Int32
    public var schedulerPolicy: Int32
    public var sleepTimeSeconds: Int32
    public var flags: Int32
    public var dispatchQueueAddress: UInt64?

    public init(
        id: UInt64,
        name: String = "",
        cpuPercent: Double = 0,
        cpuTime: UInt64 = 0,
        state: String = "",
        startAddress: UInt64? = nil,
        startSymbol: String? = nil,
        currentPriority: Int32 = 0,
        basePriority: Int32 = 0,
        maxPriority: Int32 = 0,
        schedulerPolicy: Int32 = 0,
        sleepTimeSeconds: Int32 = 0,
        flags: Int32 = 0,
        dispatchQueueAddress: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.cpuTime = cpuTime
        self.state = state
        self.startAddress = startAddress
        self.startSymbol = startSymbol
        self.currentPriority = currentPriority
        self.basePriority = basePriority
        self.maxPriority = maxPriority
        self.schedulerPolicy = schedulerPolicy
        self.sleepTimeSeconds = sleepTimeSeconds
        self.flags = flags
        self.dispatchQueueAddress = dispatchQueueAddress
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
    public var openFlags: UInt32?
    public var statusFlags: UInt32?
    public var offset: Int64?
    public var fileInfoType: Int32?
    public var guardFlags: UInt32?
    public var vnode: VnodeDescriptorInfo?
    public var socket: SocketInfo?

    public init(
        id: Int32,
        kind: FDKind,
        name: String,
        openFlags: UInt32? = nil,
        statusFlags: UInt32? = nil,
        offset: Int64? = nil,
        fileInfoType: Int32? = nil,
        guardFlags: UInt32? = nil,
        vnode: VnodeDescriptorInfo? = nil,
        socket: SocketInfo? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.openFlags = openFlags
        self.statusFlags = statusFlags
        self.offset = offset
        self.fileInfoType = fileInfoType
        self.guardFlags = guardFlags
        self.vnode = vnode
        self.socket = socket
    }
}

public enum VnodeKind: String, Sendable, Codable {
    case regular
    case directory
    case symbolicLink
    case characterDevice
    case blockDevice
    case socket
    case fifo
    case unknown
}

public struct VnodeDescriptorInfo: Sendable, Codable, Hashable {
    public var typeRaw: Int32
    public var type: VnodeKind
    public var mode: UInt16
    public var deviceID: UInt32
    public var specialDeviceID: UInt32
    public var inode: UInt64
    public var size: Int64
    public var accessTime: Date?
    public var modificationTime: Date?
    public var statusChangeTime: Date?
    public var birthTime: Date?

    public init(
        typeRaw: Int32,
        type: VnodeKind,
        mode: UInt16,
        deviceID: UInt32,
        specialDeviceID: UInt32,
        inode: UInt64,
        size: Int64,
        accessTime: Date? = nil,
        modificationTime: Date? = nil,
        statusChangeTime: Date? = nil,
        birthTime: Date? = nil
    ) {
        self.typeRaw = typeRaw
        self.type = type
        self.mode = mode
        self.deviceID = deviceID
        self.specialDeviceID = specialDeviceID
        self.inode = inode
        self.size = size
        self.accessTime = accessTime
        self.modificationTime = modificationTime
        self.statusChangeTime = statusChangeTime
        self.birthTime = birthTime
    }
}

public enum SocketProto: String, Sendable, Codable {
    case tcp4
    case tcp6
    case udp4
    case udp6
}

public struct SocketInfo: Identifiable, Sendable, Codable, Hashable {
    public var id: Int32             // fd
    public var proto: SocketProto
    public var localAddress: String
    public var localPort: UInt16
    public var remoteAddress: String
    public var remotePort: UInt16
    public var state: String
    public var addressFamily: Int32?
    public var socketType: Int32?
    public var protocolNumber: Int32?
    public var socketKind: Int32?
    public var socketOptions: UInt16?
    public var socketStateFlags: UInt16?
    public var linger: Int16?
    public var socketTimeout: Int16?
    public var socketError: UInt16?
    public var outOfBandMark: UInt32?
    public var queueLength: Int16?
    public var incompleteQueueLength: Int16?
    public var queueLimit: Int16?
    public var receiveBuffer: SocketBufferInfo?
    public var sendBuffer: SocketBufferInfo?
    public var tcpStateRaw: Int32?
    public var tcpMaximumSegmentSize: Int32?
    public var tcpFlags: UInt32?
    public var tcpTimers: TCPTimerInfo?

    public init(
        id: Int32,
        proto: SocketProto,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        state: String,
        addressFamily: Int32? = nil,
        socketType: Int32? = nil,
        protocolNumber: Int32? = nil,
        socketKind: Int32? = nil,
        socketOptions: UInt16? = nil,
        socketStateFlags: UInt16? = nil,
        linger: Int16? = nil,
        socketTimeout: Int16? = nil,
        socketError: UInt16? = nil,
        outOfBandMark: UInt32? = nil,
        queueLength: Int16? = nil,
        incompleteQueueLength: Int16? = nil,
        queueLimit: Int16? = nil,
        receiveBuffer: SocketBufferInfo? = nil,
        sendBuffer: SocketBufferInfo? = nil,
        tcpStateRaw: Int32? = nil,
        tcpMaximumSegmentSize: Int32? = nil,
        tcpFlags: UInt32? = nil,
        tcpTimers: TCPTimerInfo? = nil
    ) {
        self.id = id
        self.proto = proto
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.addressFamily = addressFamily
        self.socketType = socketType
        self.protocolNumber = protocolNumber
        self.socketKind = socketKind
        self.socketOptions = socketOptions
        self.socketStateFlags = socketStateFlags
        self.linger = linger
        self.socketTimeout = socketTimeout
        self.socketError = socketError
        self.outOfBandMark = outOfBandMark
        self.queueLength = queueLength
        self.incompleteQueueLength = incompleteQueueLength
        self.queueLimit = queueLimit
        self.receiveBuffer = receiveBuffer
        self.sendBuffer = sendBuffer
        self.tcpStateRaw = tcpStateRaw
        self.tcpMaximumSegmentSize = tcpMaximumSegmentSize
        self.tcpFlags = tcpFlags
        self.tcpTimers = tcpTimers
    }
}

public struct SocketBufferInfo: Sendable, Codable, Hashable {
    public var currentBytes: UInt32
    public var highWaterMark: UInt32
    public var mbufBytes: UInt32
    public var mbufLimit: UInt32
    public var lowWaterMark: UInt32
    public var flags: Int16
    public var timeout: Int16

    public init(
        currentBytes: UInt32,
        highWaterMark: UInt32,
        mbufBytes: UInt32,
        mbufLimit: UInt32,
        lowWaterMark: UInt32,
        flags: Int16,
        timeout: Int16
    ) {
        self.currentBytes = currentBytes
        self.highWaterMark = highWaterMark
        self.mbufBytes = mbufBytes
        self.mbufLimit = mbufLimit
        self.lowWaterMark = lowWaterMark
        self.flags = flags
        self.timeout = timeout
    }
}

public struct TCPTimerInfo: Sendable, Codable, Hashable {
    public var retransmit: Int32
    public var persist: Int32
    public var keepAlive: Int32
    public var twoMSL: Int32

    public init(retransmit: Int32, persist: Int32, keepAlive: Int32, twoMSL: Int32) {
        self.retransmit = retransmit
        self.persist = persist
        self.keepAlive = keepAlive
        self.twoMSL = twoMSL
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
    public var validationErrorCode: Int32?
    public var validationErrorMessage: String?

    public init(
        status: SigningStatus = .unverified,
        teamID: String? = nil,
        authority: [String] = [],
        isNotarized: Bool = false,
        isPlatformBinary: Bool = false,
        isAdHoc: Bool = false,
        sha256: String? = nil,
        virusTotal: VirusTotalResult? = nil,
        validationErrorCode: Int32? = nil,
        validationErrorMessage: String? = nil
    ) {
        self.status = status
        self.teamID = teamID
        self.authority = authority
        self.isNotarized = isNotarized
        self.isPlatformBinary = isPlatformBinary
        self.isAdHoc = isAdHoc
        self.sha256 = sha256
        self.virusTotal = virusTotal
        self.validationErrorCode = validationErrorCode
        self.validationErrorMessage = validationErrorMessage
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

    public var publisherDescription: String? {
        if isPlatformBinary { return "Apple (platform)" }
        if let first = authority.first, !first.isEmpty { return first }
        if let teamID, !teamID.isEmpty { return "Team \(teamID)" }
        return nil
    }
}
