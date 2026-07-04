//
//  CPUDeltaTracker.swift
//  ProcexpSampling — W1
//
//  Keeps the previous sample's cumulative CPU time per process so we can turn
//  monotonically-increasing CPU-time counters into an instantaneous percentage.
//  An `actor` guarantees the mutable state is accessed serially and stays
//  `Sendable`-safe across the async sampling loop.
//

import Foundation
import ProcexpModel

actor CPUDeltaTracker {
    /// Cumulative CPU time (user+system, nanoseconds) at the previous sample.
    private var previousCPU: [ProcessID: UInt64] = [:]
    /// Monotonic wall-clock (nanoseconds) at the previous sample.
    private var previousWallNanos: UInt64 = 0

    /// Given the current cumulative CPU times and the current wall clock,
    /// return the per-process CPU percentage where `100.0 == one busy core`.
    /// The first call (no prior sample) yields all-zero percentages.
    func percentages(
        current: [ProcessID: UInt64],
        wallNanos: UInt64
    ) -> [ProcessID: Double] {
        var result: [ProcessID: Double] = [:]
        result.reserveCapacity(current.count)

        let wallDelta = previousWallNanos == 0 ? 0 : wallNanos &- previousWallNanos
        for (id, cpu) in current {
            if wallDelta > 0, let prev = previousCPU[id], cpu >= prev {
                let cpuDelta = cpu - prev
                result[id] = Double(cpuDelta) / Double(wallDelta) * 100.0
            } else {
                result[id] = 0
            }
        }

        previousCPU = current
        previousWallNanos = wallNanos
        return result
    }

    /// Forget all accumulated state (e.g. when a fresh stream starts).
    func reset() {
        previousCPU.removeAll(keepingCapacity: true)
        previousWallNanos = 0
    }
}
