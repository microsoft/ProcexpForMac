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
    var cacheLineSize: UInt64?
    var l1InstructionCache: UInt64?
    var l1DataCache: UInt64?
    var l2Cache: UInt64?
    var l3Cache: UInt64?

    // MARK: Memory

    var physicalMemory: UInt64        // hw.memsize
    var pageSize: UInt64              // hw.pagesize

    // MARK: GPU / storage

    var gpus: [GPUInfo]
    var bootVolume: VolumeInfo?
    var volumes: [VolumeInfo]
    var networkInterfaces: [NetworkInterfaceInfo]

    /// A Metal-enumerated graphics device.
    struct GPUInfo: Sendable, Identifiable {
        var id: Int
        var name: String
        var vram: UInt64?             // recommendedMaxWorkingSetSize
        var unifiedMemory: Bool       // hasUnifiedMemory
        var lowPower: Bool
        var removable: Bool
        var headless: Bool
        var registryID: UInt64
        var maxThreadsPerThreadgroup: String
        var maxBufferLength: UInt64
        var argumentBuffersTier: String
        var readWriteTextureTier: String
    }

    /// A mounted volume (currently the boot / root volume).
    struct VolumeInfo: Sendable {
        var name: String
        var totalCapacity: UInt64
        var availableCapacity: UInt64
        var formatDescription: String?
        var isInternal: Bool?
        var isRemovable: Bool?
        var isEjectable: Bool?
        var isReadOnly: Bool?
        /// Approximate media type. Internal Apple Silicon storage is always
        /// flash, so it is reported as "SSD"; probing rotational media on Intel
        /// externally is not attempted here.
        var mediaType: String
    }

    struct NetworkInterfaceInfo: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var families: [String]
        var addresses: [String]
        var isUp: Bool
        var isRunning: Bool
        var isLoopback: Bool
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
        let cacheLine = sysctlUInt("hw.cachelinesize")
        let l1i = sysctlUInt("hw.l1icachesize")
        let l1d = sysctlUInt("hw.l1dcachesize")
        let l2 = sysctlUInt("hw.l2cachesize")
        let l3 = sysctlUInt("hw.l3cachesize")

        // --- Memory ---
        let memSize = sysctlUInt("hw.memsize") ?? processInfo.physicalMemory
        let pageSize = sysctlUInt("hw.pagesize") ?? UInt64(getpagesize())

        // --- GPUs (Metal) ---
        let gpus = gatherGPUs()

        // --- Boot volume ---
        let bootVolume = gatherBootVolume()
        let volumes = gatherVolumes(bootVolume: bootVolume)

        let interfaces = gatherNetworkInterfaces()

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
            cacheLineSize: cacheLine,
            l1InstructionCache: l1i,
            l1DataCache: l1d,
            l2Cache: l2,
            l3Cache: l3,
            physicalMemory: memSize,
            pageSize: pageSize,
            gpus: gpus,
            bootVolume: bootVolume,
            volumes: volumes,
            networkInterfaces: interfaces
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
                headless: device.isHeadless,
                registryID: device.registryID,
                maxThreadsPerThreadgroup: "\(device.maxThreadsPerThreadgroup.width) x \(device.maxThreadsPerThreadgroup.height) x \(device.maxThreadsPerThreadgroup.depth)",
                maxBufferLength: UInt64(device.maxBufferLength),
                argumentBuffersTier: argumentBuffersTierName(device.argumentBuffersSupport),
                readWriteTextureTier: readWriteTextureTierName(device.readWriteTextureSupport)
            )
        }
    }

    static func argumentBuffersTierName(_ tier: MTLArgumentBuffersTier) -> String {
        switch tier {
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        @unknown default: return "Tier \(tier.rawValue)"
        }
    }

    static func readWriteTextureTierName(_ tier: MTLReadWriteTextureTier) -> String {
        switch tier {
        case .tierNone: return "None"
        case .tier1: return "Tier 1"
        case .tier2: return "Tier 2"
        @unknown default: return "Tier \(tier.rawValue)"
        }
    }

    static func gatherBootVolume() -> VolumeInfo? {
        volumeInfo(for: URL(fileURLWithPath: "/"), defaultName: "Macintosh HD")
    }

    static func gatherVolumes(bootVolume: VolumeInfo?) -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        var volumes: [VolumeInfo] = []
        if let bootVolume { volumes.append(bootVolume) }
        volumes += urls
            .compactMap { volumeInfo(for: $0, defaultName: $0.lastPathComponent) }
            .filter { volume in
                guard volume.totalCapacity > 0 else { return false }
                guard volume.isInternal != true else { return false }
                guard volume.isRemovable == true || volume.isEjectable == true else { return false }
                return volume.totalCapacity >= 8 * 1024 * 1024 * 1024
            }
        var seen = Set<String>()
        return volumes.filter { volume in
            let key = "\(volume.name)|\(volume.totalCapacity)|\(volume.isInternal == true)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    static func volumeInfo(for url: URL, defaultName: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let name = values.volumeName ?? defaultName
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
            formatDescription: values.volumeLocalizedFormatDescription,
            isInternal: values.volumeIsInternal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable,
            isReadOnly: values.volumeIsReadOnly,
            mediaType: mediaType
        )
    }

    static func gatherNetworkInterfaces() -> [NetworkInterfaceInfo] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }

        var byName: [String: NetworkInterfaceInfo] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let name = String(cString: item.pointee.ifa_name)
            let flags = Int32(item.pointee.ifa_flags)
            guard let formatted = formatAddress(address, family: family) else { continue }
            let isLoopback = flags & IFF_LOOPBACK != 0
            if isLoopback { continue }
            let familyName = family == AF_INET ? "IPv4" : "IPv6"
            if var existing = byName[name] {
                if !existing.families.contains(familyName) { existing.families.append(familyName) }
                if !existing.addresses.contains(formatted) { existing.addresses.append(formatted) }
                existing.isUp = existing.isUp || flags & IFF_UP != 0
                existing.isRunning = existing.isRunning || flags & IFF_RUNNING != 0
                byName[name] = existing
            } else {
                byName[name] = NetworkInterfaceInfo(
                    name: name,
                    families: [familyName],
                    addresses: [formatted],
                    isUp: flags & IFF_UP != 0,
                    isRunning: flags & IFF_RUNNING != 0,
                    isLoopback: false
                )
            }
        }
        return byName.values
            .filter { $0.isUp || $0.isRunning }
            .sorted { $0.name < $1.name }
    }

    static func formatAddress(_ address: UnsafePointer<sockaddr>, family: Int32) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = family == AF_INET
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        let status = getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? String(cString: host) : nil
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
