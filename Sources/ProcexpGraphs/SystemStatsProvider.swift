//
//  SystemStatsProvider.swift
//  ProcexpGraphs — W4
//
//  A real `SystemStatsProviding` backed by Mach host statistics, sysctl, and IOKit.
//
//  What is REAL here:
//    - cpuTotalPercent + perCoreCPUPercent : host_processor_info CPU-load ticks,
//      delta'd against the previous sample (first call returns zeros).
//    - memoryUsed / memoryWired / memoryCompressed / memoryTotal : host_statistics64
//      (HOST_VM_INFO64) + HW_MEMSIZE sysctl.
//    - swapUsed : sysctl VM_SWAPUSAGE (xsw_usage.xsu_used).
//    - networkBytesPerSec : sysctl NET_RT_IFLIST2 interface byte counters, delta'd.
//    - diskBytesPerSec : IOKit IOBlockStorageDriver byte counters, delta'd.
//
//  What is DEFERRED (left 0 by design — documented):
//    - processCount / threadCount / handleCount : filled by the sampling engine (W1),
//      not by this provider.
//    - gpuPercent : provided elsewhere (W9 GPUStatsProvider); left nil here.
//

import Foundation
import Darwin
import IOKit
import ProcexpModel

// MARK: - Delta state (actor for Sendable-safe previous-sample bookkeeping)

/// Holds the previous samples needed to turn cumulative counters into rates.
private actor SystemStatsDeltaState {
    /// Per-core cumulative ticks from the previous CPU sample.
    /// Each entry is (user, system, idle, nice).
    var previousCPUTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []

    /// Previous aggregate network byte counters (ibytes + obytes across ifaces).
    var previousNetworkBytes: UInt64?
    /// Timestamp of the previous network sample.
    var previousNetworkTime: TimeInterval?
    var previousDiskBytes: UInt64?
    var previousDiskTime: TimeInterval?

    func updateCPU(
        _ new: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)]
    ) -> (total: Double, perCore: [Double]) {
        defer { previousCPUTicks = new }

        // First sample (or core-count change): no delta available yet.
        guard previousCPUTicks.count == new.count, !previousCPUTicks.isEmpty else {
            return (0, Array(repeating: 0, count: new.count))
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(new.count)
        for (index, cur) in new.enumerated() {
            let prev = previousCPUTicks[index]
            // Ticks are cumulative UInt32; use wrapping subtraction to survive rollover.
            let dUser = Double(cur.user &- prev.user)
            let dSystem = Double(cur.system &- prev.system)
            let dIdle = Double(cur.idle &- prev.idle)
            let dNice = Double(cur.nice &- prev.nice)
            let busy = dUser + dSystem + dNice
            let total = busy + dIdle
            let percent = total > 0 ? (busy / total) * 100 : 0
            perCore.append(percent)
        }
        let avg = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return (avg, perCore)
    }

    func updateNetwork(totalBytes: UInt64, now: TimeInterval) -> UInt64 {
        updateRate(totalBytes: totalBytes, now: now, previousBytes: &previousNetworkBytes, previousTime: &previousNetworkTime)
    }

    func updateDisk(totalBytes: UInt64, now: TimeInterval) -> UInt64 {
        updateRate(totalBytes: totalBytes, now: now, previousBytes: &previousDiskBytes, previousTime: &previousDiskTime)
    }

    private func updateRate(
        totalBytes: UInt64,
        now: TimeInterval,
        previousBytes: inout UInt64?,
        previousTime: inout TimeInterval?
    ) -> UInt64 {
        defer {
            previousBytes = totalBytes
            previousTime = now
        }
        guard let prevBytes = previousBytes,
              let prevTime = previousTime else {
            return 0
        }
        let dt = now - prevTime
        guard dt > 0 else { return 0 }
        // Counters are monotonically increasing; guard against wraparound/reset.
        let deltaBytes = totalBytes >= prevBytes ? (totalBytes - prevBytes) : 0
        return UInt64(Double(deltaBytes) / dt)
    }
}

// MARK: - Provider

public final class SystemStatsProvider: SystemStatsProviding {
    private let state = SystemStatsDeltaState()

    public init() {}

    public func stats() async -> SystemStats {
        let cpuTicks = Self.readPerCoreCPUTicks()
        let (cpuTotal, perCore) = await state.updateCPU(cpuTicks)

        let mem = Self.readMemory()
        let swap = Self.readSwapUsed()

        let now = ProcessInfo.processInfo.systemUptime
        let netTotal = Self.readTotalNetworkBytes()
        let netRate: UInt64
        if let netTotal {
            netRate = await state.updateNetwork(
                totalBytes: netTotal,
                now: now
            )
        } else {
            netRate = 0
        }

        let diskTotal = Self.readTotalDiskBytes()
        let diskRate: UInt64
        if let diskTotal {
            diskRate = await state.updateDisk(totalBytes: diskTotal, now: now)
        } else {
            diskRate = 0
        }

        return SystemStats(
            cpuTotalPercent: cpuTotal,
            perCoreCPUPercent: perCore,
            memoryUsed: mem.used,
            memoryTotal: mem.total,
            memoryWired: mem.wired,
            memoryCompressed: mem.compressed,
            swapUsed: swap,
            diskBytesPerSec: diskRate,
            networkBytesPerSec: netRate,
            gpuPercent: nil,              // provided by W9 GPUStatsProvider
            processCount: 0,             // filled by W1 sampling engine
            threadCount: 0,              // filled by W1 sampling engine
            handleCount: 0               // filled by W1 sampling engine
        )
    }

    // MARK: CPU

    /// Reads cumulative per-core CPU-load ticks via `host_processor_info`.
    private static func readPerCoreCPUTicks()
        -> [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let infoArray else {
            return []
        }
        defer {
            // Free the vm-allocated array returned by the kernel.
            let size = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: infoArray)),
                          size)
        }

        // The kernel returns CPU_STATE_MAX integer_t values per core.
        var ticks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        ticks.reserveCapacity(Int(cpuCount))
        let stateCount = Int(CPU_STATE_MAX)
        for core in 0..<Int(cpuCount) {
            let base = core * stateCount
            let user = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
            ticks.append((user: user, system: system, idle: idle, nice: nice))
        }
        return ticks
    }

    // MARK: Memory

    private struct MemorySample {
        var used: UInt64 = 0
        var total: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
    }

    private static func readMemory() -> MemorySample {
        var sample = MemorySample()
        sample.total = readPhysicalMemory()

        let pageSize = readPageSize()

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return sample
        }

        let wiredBytes = UInt64(vmStats.wire_count) * pageSize
        let compressedBytes = UInt64(vmStats.compressor_page_count) * pageSize
        let activeBytes = UInt64(vmStats.active_count) * pageSize

        sample.wired = wiredBytes
        sample.compressed = compressedBytes
        // Process Explorer's "in use" ~= active + wired + compressed.
        sample.used = activeBytes + wiredBytes + compressedBytes
        return sample
    }

    private static func readPageSize() -> UInt64 {
        var pageSize: vm_size_t = 0
        let result = host_page_size(mach_host_self(), &pageSize)
        return result == KERN_SUCCESS ? UInt64(pageSize) : 4096
    }

    private static func readPhysicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        let result = sysctl(&mib, u_int(mib.count), &size, &len, nil, 0)
        return result == 0 ? size : 0
    }

    // MARK: Swap

    private static func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let result = sysctl(&mib, u_int(mib.count), &usage, &len, nil, 0)
        return result == 0 ? usage.xsu_used : 0
    }

    // MARK: Network

    /// Sums cumulative ibytes+obytes across all interfaces via NET_RT_IFLIST2.
    /// Returns nil if the interface list cannot be read.
    private static func readTotalNetworkBytes() -> UInt64? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: len)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &len, nil, 0) == 0
        }
        guard ok else { return nil }

        var total: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdrPtr = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self)
                let msgLen = Int(hdrPtr.pointee.ifm_msglen)
                if msgLen == 0 { break }
                if hdrPtr.pointee.ifm_type == RTM_IFINFO2 {
                    let if2Ptr = base.advanced(by: offset)
                        .assumingMemoryBound(to: if_msghdr2.self)
                    let data = if2Ptr.pointee.ifm_data
                    total &+= UInt64(data.ifi_ibytes) &+ UInt64(data.ifi_obytes)
                }
                offset += msgLen
            }
        }
        return total
    }

    private static func readTotalDiskBytes() -> UInt64? {
        var total: UInt64 = 0
        var found = false
        for serviceName in ["IOBlockStorageDriver", "AppleAPFSMedia", "AppleAPFSVolume"] {
            if let bytes = readDiskBytes(matchingServiceClass: serviceName) {
                total &+= bytes
                found = true
            }
        }
        return found ? total : nil
    }

    private static func readDiskBytes(matchingServiceClass name: String) -> UInt64? {
        guard let matching = IOServiceMatching(name) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var total: UInt64 = 0
        var found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = registryStatistics(of: service), let bytes = diskBytes(from: stats) {
                total &+= bytes
                found = true
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found ? total : nil
    }

    private static func registryStatistics(of service: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict["Statistics"] as? [String: Any]
    }

    private static func diskBytes(from stats: [String: Any]) -> UInt64? {
        let readKeys = ["Bytes (Read)", "Bytes read from block device", "Bytes read by user"]
        let writeKeys = ["Bytes (Write)", "Bytes written to block device", "Bytes written by user"]
        var found = false
        var total: UInt64 = 0
        for key in readKeys + writeKeys {
            if let number = stats[key] as? NSNumber {
                total &+= number.uint64Value
                found = true
            }
        }
        return found ? total : nil
    }
}
