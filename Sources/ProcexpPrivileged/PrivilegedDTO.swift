//
//  PrivilegedDTO.swift
//  ProcexpPrivileged — W2
//
//  Codable data-transfer objects that ferry `ProcexpModel` value types across
//  the XPC boundary as JSON. Only the fields the app actually consumes are
//  carried; the rest are reconstructed with their model defaults (or filled
//  later by the signing/network/autostart providers in the app).
//
//  `ProcessID`, `ImageType`, and `ProcessFlags` are already `Codable` in W0, so
//  the DTOs embed them directly.
//

import Foundation
import ProcexpModel

// MARK: - ProcessRecord

public struct ProcessRecordDTO: Codable, Sendable {
    public var id: ProcessID
    public var parent: ProcessID?
    public var name: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var imageType: ImageType
    public var uid: UInt32
    public var userName: String?
    public var cpuPercent: Double
    public var cpuTime: UInt64
    public var threadCount: Int
    public var contextSwitches: UInt64?
    public var residentSize: UInt64
    public var virtualSize: UInt64
    public var physFootprint: UInt64?
    public var pageFaults: UInt64?
    public var diskBytesRead: UInt64?
    public var diskBytesWritten: UInt64?
    public var fileDescriptorCount: Int?
    public var nice: Int32
    public var priority: Int32
    public var flags: ProcessFlags
    public var startTimeDate: Date

    public init(_ r: ProcessRecord) {
        id = r.id
        parent = r.parent
        name = r.name
        executablePath = r.executablePath
        bundleIdentifier = r.bundleIdentifier
        imageType = r.imageType
        uid = r.uid
        userName = r.userName
        cpuPercent = r.cpuPercent
        cpuTime = r.cpuTime
        threadCount = r.threadCount
        contextSwitches = r.contextSwitches
        residentSize = r.residentSize
        virtualSize = r.virtualSize
        physFootprint = r.physFootprint
        pageFaults = r.pageFaults
        diskBytesRead = r.diskBytesRead
        diskBytesWritten = r.diskBytesWritten
        fileDescriptorCount = r.fileDescriptorCount
        nice = r.nice
        priority = r.priority
        flags = r.flags
        startTimeDate = r.startTimeDate
    }

    public var model: ProcessRecord {
        ProcessRecord(
            id: id,
            parent: parent,
            name: name,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            imageType: imageType,
            uid: uid,
            userName: userName,
            cpuPercent: cpuPercent,
            cpuTime: cpuTime,
            threadCount: threadCount,
            contextSwitches: contextSwitches,
            residentSize: residentSize,
            virtualSize: virtualSize,
            physFootprint: physFootprint,
            pageFaults: pageFaults,
            diskBytesRead: diskBytesRead,
            diskBytesWritten: diskBytesWritten,
            fileDescriptorCount: fileDescriptorCount,
            nice: nice,
            priority: priority,
            flags: flags,
            startTimeDate: startTimeDate
        )
    }
}

// MARK: - SystemStats

public struct SystemStatsDTO: Codable, Sendable {
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
    public var handleCount: Int

    public init(_ s: SystemStats) {
        cpuTotalPercent = s.cpuTotalPercent
        perCoreCPUPercent = s.perCoreCPUPercent
        memoryUsed = s.memoryUsed
        memoryTotal = s.memoryTotal
        memoryWired = s.memoryWired
        memoryCompressed = s.memoryCompressed
        swapUsed = s.swapUsed
        diskBytesPerSec = s.diskBytesPerSec
        networkBytesPerSec = s.networkBytesPerSec
        gpuPercent = s.gpuPercent
        processCount = s.processCount
        threadCount = s.threadCount
        handleCount = s.handleCount
    }

    public var model: SystemStats {
        SystemStats(
            cpuTotalPercent: cpuTotalPercent,
            perCoreCPUPercent: perCoreCPUPercent,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            memoryWired: memoryWired,
            memoryCompressed: memoryCompressed,
            swapUsed: swapUsed,
            diskBytesPerSec: diskBytesPerSec,
            networkBytesPerSec: networkBytesPerSec,
            gpuPercent: gpuPercent,
            processCount: processCount,
            threadCount: threadCount,
            handleCount: handleCount
        )
    }
}

// MARK: - Snapshot

public struct ProcessSnapshotDTO: Codable, Sendable {
    public var timestamp: Date
    public var interval: TimeInterval
    public var processes: [ProcessRecordDTO]
    public var system: SystemStatsDTO

    public init(_ snap: ProcessSnapshot) {
        timestamp = snap.timestamp
        interval = snap.interval
        processes = snap.processes.values.map(ProcessRecordDTO.init)
        system = SystemStatsDTO(snap.system)
    }

    /// Rebuild the full snapshot, deriving `roots`/`children` locally via the
    /// shared tree builder so the wire payload stays flat.
    public var model: ProcessSnapshot {
        var map: [ProcessID: ProcessRecord] = [:]
        map.reserveCapacity(processes.count)
        for dto in processes { map[dto.id] = dto.model }
        let (roots, children) = ProcessTreeBuilder.build(from: map)
        return ProcessSnapshot(
            timestamp: timestamp,
            interval: interval,
            processes: map,
            roots: roots,
            children: children,
            system: system.model
        )
    }
}

// MARK: - ThreadInfo

public struct ThreadInfoDTO: Codable, Sendable {
    public var id: UInt64
    public var cpuPercent: Double
    public var cpuTime: UInt64
    public var state: String
    public var startAddress: UInt64?
    public var startSymbol: String?
    public var basePriority: Int32

    public init(_ t: ThreadInfo) {
        id = t.id
        cpuPercent = t.cpuPercent
        cpuTime = t.cpuTime
        state = t.state
        startAddress = t.startAddress
        startSymbol = t.startSymbol
        basePriority = t.basePriority
    }

    public init(
        id: UInt64, cpuPercent: Double, cpuTime: UInt64, state: String,
        startAddress: UInt64? = nil, startSymbol: String? = nil, basePriority: Int32
    ) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.cpuTime = cpuTime
        self.state = state
        self.startAddress = startAddress
        self.startSymbol = startSymbol
        self.basePriority = basePriority
    }

    public var model: ThreadInfo {
        ThreadInfo(
            id: id,
            cpuPercent: cpuPercent,
            cpuTime: cpuTime,
            state: state,
            startAddress: startAddress,
            startSymbol: startSymbol,
            basePriority: basePriority
        )
    }
}

// MARK: - ModuleInfo

public struct ModuleInfoDTO: Codable, Sendable {
    public var path: String
    public var name: String
    public var loadAddress: UInt64
    public var size: UInt64
    public var isMappedFile: Bool

    public init(_ m: ModuleInfo) {
        path = m.path
        name = m.name
        loadAddress = m.loadAddress
        size = m.size
        isMappedFile = m.isMappedFile
    }

    public var model: ModuleInfo {
        ModuleInfo(
            path: path,
            name: name,
            loadAddress: loadAddress,
            size: size,
            isMappedFile: isMappedFile
        )
    }
}

// MARK: - FileDescriptorInfo

public struct FileDescriptorInfoDTO: Codable, Sendable {
    public var id: Int32
    public var kind: FDKind
    public var name: String

    public init(_ f: FileDescriptorInfo) {
        id = f.id
        kind = f.kind
        name = f.name
    }

    public var model: FileDescriptorInfo {
        FileDescriptorInfo(id: id, kind: kind, name: name)
    }
}
