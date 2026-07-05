//
//  ThreadSampler.swift
//  ProcexpHelper — W2 (privileged root daemon)
//
//  Real per-thread detail via a task port. This is the one thing the
//  unprivileged `LibprocDataProvider` genuinely cannot do: obtaining
//  `task_for_pid` for another process requires root (or a special
//  entitlement), after which `task_threads` + `thread_info` yield accurate
//  per-thread CPU usage, cumulative time, run state, and TID.
//
//  Every Mach call is guarded; a process that dies mid-sample simply yields
//  `nil`/`[]` and never traps. All acquired ports are released.
//

import Foundation
import Darwin
import ProcexpModel
import ProcexpPrivileged

enum ThreadSampler {

    /// `mach_usage` values are scaled by this factor (`TH_USAGE_SCALE`).
    private static let usageScale = 1000.0

    private static func fixedChars<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Real per-thread info for `pid`, or `nil` if the task port is
    /// unobtainable (process gone, or — under ad-hoc signing — `task_for_pid`
    /// is denied even to root without the debugging entitlement).
    static func threads(pid: pid_t) -> [ThreadInfoDTO]? {
        var task = mach_port_t()
        guard task_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(task, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        let basicCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let extendedCount = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let idCount = mach_msg_type_number_t(
            MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        var result: [ThreadInfoDTO] = []
        result.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }

            // Basic info: CPU usage, cumulative time, run state, priority.
            var basic = thread_basic_info_data_t()
            var bCount = basicCount
            let bkr = withUnsafeMutablePointer(to: &basic) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &bCount)
                }
            }
            guard bkr == KERN_SUCCESS else { continue }

            var cpuPercent = Double(basic.cpu_usage) / usageScale * 100.0
            var userTime = time(basic.user_time)
            var kernelTime = time(basic.system_time)
            var cpuTime = userTime &+ kernelTime
            var runState = basic.run_state
            var name = ""
            var currentPriority: Int32 = 0
            var basePriority: Int32 = 0
            var maxPriority: Int32 = 0
            var schedulerPolicy: Int32 = 0
            var sleepTimeSeconds: Int32 = 0
            var flags: Int32 = 0

            var extended = thread_extended_info_data_t()
            var eCount = extendedCount
            let ekr = withUnsafeMutablePointer(to: &extended) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(eCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &eCount)
                }
            }
            if ekr == KERN_SUCCESS {
                cpuPercent = Double(extended.pth_cpu_usage) / usageScale * 100.0
                userTime = extended.pth_user_time
                kernelTime = extended.pth_system_time
                cpuTime = userTime &+ kernelTime
                runState = extended.pth_run_state
                name = fixedChars(extended.pth_name)
                currentPriority = extended.pth_curpri
                basePriority = extended.pth_priority
                maxPriority = extended.pth_maxpriority
                schedulerPolicy = extended.pth_policy
                sleepTimeSeconds = extended.pth_sleep_time
                flags = extended.pth_flags
            }

            // Stable thread id (TID).
            var idInfo = thread_identifier_info_data_t()
            var iCount = idCount
            let ikr = withUnsafeMutablePointer(to: &idInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(iCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &iCount)
                }
            }
            let tid: UInt64 = ikr == KERN_SUCCESS ? idInfo.thread_id : UInt64(i)
            let dispatchQueueAddress = ikr == KERN_SUCCESS && idInfo.dispatch_qaddr != 0
                ? idInfo.dispatch_qaddr
                : nil

            result.append(
                ThreadInfoDTO(
                    id: tid,
                    name: name,
                    cpuPercent: cpuPercent,
                    cpuTime: cpuTime,
                    userTime: userTime,
                    kernelTime: kernelTime,
                    state: stateString(runState),
                    currentPriority: currentPriority,
                    basePriority: basePriority
                    , maxPriority: maxPriority,
                    schedulerPolicy: schedulerPolicy,
                    sleepTimeSeconds: sleepTimeSeconds,
                    flags: flags,
                    dispatchQueueAddress: dispatchQueueAddress
                )
            )
        }
        return result
    }

    /// Convert a Mach `time_value_t` (seconds + microseconds) to nanoseconds.
    private static func time(_ t: time_value_t) -> UInt64 {
        UInt64(max(0, t.seconds)) &* 1_000_000_000 &+ UInt64(max(0, t.microseconds)) &* 1_000
    }

    private static func stateString(_ runState: integer_t) -> String {
        switch runState {
        case TH_STATE_RUNNING: return "running"
        case TH_STATE_STOPPED: return "stopped"
        case TH_STATE_WAITING: return "waiting"
        case TH_STATE_UNINTERRUPTIBLE: return "uninterruptible"
        case TH_STATE_HALTED: return "halted"
        default:                       return "unknown"
        }
    }
}
