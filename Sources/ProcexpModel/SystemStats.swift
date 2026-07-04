//
//  SystemStats.swift
//  ProcexpModel — W0 shared contracts
//
//  System-wide statistics and a fixed-capacity history ring for graphs.
//

import Foundation

public struct SystemStats: Sendable, Hashable {
    public var cpuTotalPercent: Double        // 0...100 (averaged across cores)
    public var perCoreCPUPercent: [Double]    // each 0...100
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
    public var handleCount: Int               // total open file descriptors

    public init(
        cpuTotalPercent: Double = 0,
        perCoreCPUPercent: [Double] = [],
        memoryUsed: UInt64 = 0,
        memoryTotal: UInt64 = 0,
        memoryWired: UInt64 = 0,
        memoryCompressed: UInt64 = 0,
        swapUsed: UInt64 = 0,
        diskBytesPerSec: UInt64 = 0,
        networkBytesPerSec: UInt64 = 0,
        gpuPercent: Double? = nil,
        processCount: Int = 0,
        threadCount: Int = 0,
        handleCount: Int = 0
    ) {
        self.cpuTotalPercent = cpuTotalPercent
        self.perCoreCPUPercent = perCoreCPUPercent
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryWired = memoryWired
        self.memoryCompressed = memoryCompressed
        self.swapUsed = swapUsed
        self.diskBytesPerSec = diskBytesPerSec
        self.networkBytesPerSec = networkBytesPerSec
        self.gpuPercent = gpuPercent
        self.processCount = processCount
        self.threadCount = threadCount
        self.handleCount = handleCount
    }

    public static let zero = SystemStats()
}

/// Fixed-capacity ring buffer used to back the history graphs. Appending past
/// capacity discards the oldest sample. `values` returns oldest → newest.
public struct HistoryRing<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "HistoryRing capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public mutating func append(_ value: Element) {
        storage.append(value)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Samples ordered oldest → newest.
    public var values: [Element] { storage }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var latest: Element? { storage.last }

    public mutating func removeAll() { storage.removeAll(keepingCapacity: true) }
}
