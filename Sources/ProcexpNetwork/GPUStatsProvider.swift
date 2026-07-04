//
//  GPUStatsProvider.swift
//  ProcexpNetwork — W9 (best-effort GPU)
//
//  System-wide GPU utilization via the IOKit registry. We match the
//  "IOAccelerator" service (the graphics-accelerator nub each GPU publishes)
//  and read its "PerformanceStatistics" dictionary, which contains vendor-
//  provided counters such as "Device Utilization %".
//

import Foundation
import IOKit

/// Best-effort GPU statistics.
///
/// Stateless value with no stored mutable state, so it is trivially `Sendable`.
public final class GPUStatsProvider {

    public init() {}

    /// Current system-wide GPU utilization as a percentage (0...100), or `nil`
    /// if no accelerator publishes a utilization counter.
    ///
    /// If multiple GPUs are present, the highest reported utilization is
    /// returned (the busiest device best reflects "is the GPU working?").
    ///
    /// ## Limitation: no per-process GPU
    /// macOS does not expose per-process GPU usage through any public API.
    /// Activity Monitor's per-process GPU figures come from private
    /// entitlements / frameworks that are unavailable to third-party apps, so
    /// `ProcessRecord.gpuPercent` cannot be populated here — only this
    /// system-wide aggregate is obtainable.
    public func systemGPUPercent() async -> Double? {
        // Try the accelerator nub first, then the older accelerator class name.
        for serviceName in ["IOAccelerator", "IOGraphicsAccelerator2"] {
            if let value = Self.utilization(matchingServiceClass: serviceName) {
                return value
            }
        }
        return nil
    }

    private static func utilization(matchingServiceClass name: String) -> Double? {
        guard let matching = IOServiceMatching(name) else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let perf = performanceStatistics(of: service),
               let util = deviceUtilization(from: perf) {
                best = max(best ?? 0, util)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    private static func performanceStatistics(of service: io_registry_entry_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict["PerformanceStatistics"] as? [String: Any]
    }

    /// Pull a utilization percentage out of a PerformanceStatistics dictionary.
    /// Different drivers use different keys; we probe the common ones in order.
    private static func deviceUtilization(from perf: [String: Any]) -> Double? {
        let keys = ["Device Utilization %", "GPU Core Utilization", "Renderer Utilization %"]
        for key in keys {
            guard let raw = perf[key] as? NSNumber else { continue }
            var value = raw.doubleValue
            // Some drivers report core utilization scaled by 10,000,000
            // (i.e. 0...10_000_000). Normalize anything obviously out of the
            // percentage range back down to 0...100.
            if key == "GPU Core Utilization", value > 100 {
                value /= 10_000_00.0 * 10.0   // 10_000_000 -> percent
            }
            if value >= 0 {
                return min(value, 100)
            }
        }
        return nil
    }
}
