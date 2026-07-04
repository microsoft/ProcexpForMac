//
//  HardwareInfo.swift
//  Static hardware / resource description for the System Information window.
//
//  Process Explorer's System Information view describes *what* each resource is
//  (CPU model, core layout, RAM, GPUs, disks) alongside the live graphs. macOS
//  exposes this through `sysctl`, Metal (`MTLCopyAllDevices`) and Foundation's
//  volume resource keys. Hardware doesn't change while the app runs, so the
//  whole thing is gathered once via `HardwareInfo.current` and cached.
//
//  All stored state is value-type (Strings / Ints), so `HardwareInfo` is a
//  trivially `Sendable`, cacheable snapshot.
//

import Foundation
import Metal
import Darwin

/// Immutable description of the machine's fixed hardware. Read once, cached.
struct HardwareInfo: Sendable {

    // MARK: Machine

    var machineModel: String          // hw.model, e.g. "Mac15,3"
    var architecture: String          // hw.machine, e.g. "arm64"
    var osVersion: String             // "macOS 26.5 (…)"
    var hostName: String

    // MARK: CPU

    var cpuBrand: String              // machdep.cpu.brand_string or marketing name
    var physicalCores: Int            // hw.physicalcpu
    var logicalCores: Int             // hw.logicalcpu
    var performanceCores: Int?        // hw.perflevel0.physicalcpu (Apple Silicon)
    var efficiencyCores: Int?         // hw.perflevel1.physicalcpu (Apple Silicon)
    var packages: Int                 // hw.packages (sockets)
    var cpuFrequencyHz: UInt64?       // hw.cpufrequency (0/absent on Apple Silicon)

    // MARK: Memory

    var physicalMemory: UInt64        // hw.memsize
    var pageSize: UInt64              // hw.pagesize

    // MARK: GPU / storage

    var gpus: [GPUInfo]
    var bootVolume: VolumeInfo?

    /// A Metal-enumerated graphics device.
    struct GPUInfo: Sendable, Identifiable {
        var id: Int
        var name: String
        var vram: UInt64?             // recommendedMaxWorkingSetSize
        var unifiedMemory: Bool       // hasUnifiedMemory
        var lowPower: Bool
        var removable: Bool
        var headless: Bool
    }

    /// A mounted volume (currently the boot / root volume).
    struct VolumeInfo: Sendable {
        var name: String
        var totalCapacity: UInt64
        var availableCapacity: UInt64
        /// Approximate media type. Internal Apple Silicon storage is always
        /// flash, so it is reported as "SSD"; probing rotational media on Intel
        /// externally is not attempted here.
        var mediaType: String
    }

    // MARK: - Cached accessor

    /// The machine's hardware, gathered on first access and reused thereafter.
    static let current: HardwareInfo = HardwareInfo.gather()

    // MARK: - Derived display helpers

    /// "10 cores (6P + 4E)" / "8 cores" — a compact core-layout summary.
    var coreSummary: String {
        if let p = performanceCores, let e = efficiencyCores, p > 0 || e > 0 {
            return "\(physicalCores) cores (\(p)P + \(e)E)"
        }
        return "\(physicalCores) cores"
    }

    /// "8 physical / 8 logical • 1 package" style detail line.
    var cpuTopologyDetail: String {
        var parts = ["\(physicalCores) physical", "\(logicalCores) logical"]
        if packages > 1 { parts.append("\(packages) packages") }
        else { parts.append("1 package") }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Gathering

private extension HardwareInfo {

    static func gather() -> HardwareInfo {
        let processInfo = ProcessInfo.processInfo

        // --- Machine ---
        let model = sysctlString("hw.model") ?? "Mac"
        let arch = sysctlString("hw.machine") ?? "unknown"
        let osVersion = "macOS " + processInfo.operatingSystemVersionString
        let host = processInfo.hostName

        // --- CPU ---
        let brand = cpuBrandString(model: model)
        let physical = Int(sysctlUInt("hw.physicalcpu") ?? UInt64(processInfo.processorCount))
        let logical = Int(sysctlUInt("hw.logicalcpu") ?? UInt64(processInfo.activeProcessorCount))
        let pCores = sysctlUInt("hw.perflevel0.physicalcpu").map(Int.init)
        let eCores = sysctlUInt("hw.perflevel1.physicalcpu").map(Int.init)
        let packages = Int(sysctlUInt("hw.packages") ?? 1)
        let freq = sysctlUInt("hw.cpufrequency").flatMap { $0 == 0 ? nil : $0 }

        // --- Memory ---
        let memSize = sysctlUInt("hw.memsize") ?? processInfo.physicalMemory
        let pageSize = sysctlUInt("hw.pagesize") ?? UInt64(getpagesize())

        // --- GPUs (Metal) ---
        let gpus = gatherGPUs()

        // --- Boot volume ---
        let bootVolume = gatherBootVolume()

        return HardwareInfo(
            machineModel: model,
            architecture: arch,
            osVersion: osVersion,
            hostName: host,
            cpuBrand: brand,
            physicalCores: physical,
            logicalCores: logical,
            performanceCores: pCores,
            efficiencyCores: eCores,
            packages: max(packages, 1),
            cpuFrequencyHz: freq,
            physicalMemory: memSize,
            pageSize: pageSize,
            gpus: gpus,
            bootVolume: bootVolume
        )
    }

    /// Resolve a human CPU name. On Intel `machdep.cpu.brand_string` is present;
    /// on Apple Silicon that key is usually absent, so fall back to the Metal
    /// device name (e.g. "Apple M3 Pro") and finally the model identifier.
    static func cpuBrandString(model: String) -> String {
        if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty {
            return brand
        }
        // Apple Silicon: the integrated GPU name mirrors the SoC marketing name.
        if let device = MTLCreateSystemDefaultDevice(), device.name.contains("Apple") {
            return device.name
        }
        return model
    }

    static func gatherGPUs() -> [GPUInfo] {
        let devices = MTLCopyAllDevices()
        return devices.enumerated().map { index, device in
            let vram = device.recommendedMaxWorkingSetSize
            return GPUInfo(
                id: index,
                name: device.name,
                vram: vram == 0 ? nil : vram,
                unifiedMemory: device.hasUnifiedMemory,
                lowPower: device.isLowPower,
                removable: device.isRemovable,
                headless: device.isHeadless
            )
        }
    }

    static func gatherBootVolume() -> VolumeInfo? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let name = values.volumeName ?? "Macintosh HD"
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let available = UInt64(values.volumeAvailableCapacity ?? 0)

        // Apple Silicon internal storage is always flash. Report "SSD" there;
        // otherwise leave the type generic rather than probe IOKit media.
        let arch = sysctlString("hw.machine") ?? ""
        let mediaType = arch.hasPrefix("arm") ? "SSD (Flash)" : "Internal"

        return VolumeInfo(
            name: name,
            totalCapacity: total,
            availableCapacity: available,
            mediaType: mediaType
        )
    }

    // MARK: sysctl helpers

    /// Read a NUL-terminated string `sysctl` value by name.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Read an unsigned integer `sysctl` value by name (handles 32- or 64-bit).
    static func sysctlUInt(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            var value: UInt32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return UInt64(value)
        } else {
            var value: UInt64 = 0
            var s = MemoryLayout<UInt64>.size
            guard sysctlbyname(name, &value, &s, nil, 0) == 0 else { return nil }
            return value
        }
    }
}
