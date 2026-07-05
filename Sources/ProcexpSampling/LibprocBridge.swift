//
//  LibprocBridge.swift
//  ProcexpSampling — W1
//
//  Thin, self-contained wrappers over the C `libproc` / `sysctl` surface used
//  by `LibprocDataProvider`. Everything here is stateless and free of Swift
//  concurrency concerns so it can be called from any thread. All calls are
//  defensive: a process that dies mid-sample simply yields `nil`/empty.
//

import Foundation
import Darwin
import ProcexpModel

/// Namespace for the raw kernel-facing helpers.
enum Libproc {

    // MARK: - Small utilities

    /// Convert a fixed-size C `char[]` (imported into Swift as a tuple of
    /// `Int8`) into a `String`, stopping at the first NUL. Never overruns.
    @inline(__always)
    static func fixedChars<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Monotonic wall-clock nanoseconds, comparable to CPU-time nanoseconds.
    @inline(__always)
    static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // MARK: - PID enumeration

    /// All live PIDs via `proc_listallpids`.
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Pad generously in case new processes appear between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let bufSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let n = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, bufSize)
        }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    // MARK: - Per-PID BSD info (ppid / uid / nice / start time / comm)

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    /// Short BSD info is readable for *every* pid without elevated rights,
    /// including SIP-protected processes (launchd, many Apple daemons) for
    /// which `PROC_PIDTBSDINFO` returns EPERM. Used as a fallback so no process
    /// is ever dropped from the list — matching Process Explorer, which shows
    /// every pid even when detail is unavailable.
    static func shortBsdInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    // MARK: - Per-PID task info (cpu / threads / memory / faults)

    static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    // MARK: - rusage (disk I/O + phys footprint), own processes only

    struct RUsage {
        var diskRead: UInt64
        var diskWritten: UInt64
        var physFootprint: UInt64
    }

    static func rusage(_ pid: pid_t) -> RUsage? {
        var usage = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return RUsage(
            diskRead: usage.ri_diskio_bytesread,
            diskWritten: usage.ri_diskio_byteswritten,
            physFootprint: usage.ri_phys_footprint
        )
    }

    // MARK: - Names / paths

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func path(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not importable as a Swift
        // constant (the macro is flagged unavailable), so inline the value.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    // MARK: - File descriptors

    /// Count of open file descriptors (byte size / stride).
    static func fdCount(_ pid: pid_t) -> Int? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

    /// Full descriptor list with kinds and best-effort names.
    static func fileDescriptors(_ pid: pid_t) -> [FileDescriptorInfo] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let actual = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, bytes)
        }
        guard actual > 0 else { return [] }
        let n = Int(actual) / MemoryLayout<proc_fdinfo>.stride

        var result: [FileDescriptorInfo] = []
        result.reserveCapacity(n)
        for i in 0..<min(n, capacity) {
            let fd = fds[i]
            let type = Int32(bitPattern: fd.proc_fdtype)
            let kind: FDKind
            var name = ""
            switch type {
            case PROX_FDTYPE_VNODE:
                kind = .vnode
                name = vnodePath(pid: pid, fd: fd.proc_fd)
            case PROX_FDTYPE_SOCKET:
                kind = .socket
            case PROX_FDTYPE_KQUEUE:
                kind = .kqueue
            case PROX_FDTYPE_PIPE:
                kind = .pipe
            case PROX_FDTYPE_FSEVENTS:
                kind = .fsevent
            default:
                kind = .other
            }
            result.append(FileDescriptorInfo(id: fd.proc_fd, kind: kind, name: name))
        }
        return result
    }

    private static func vnodePath(pid: pid_t, fd: Int32) -> String {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, $0, size)
        }
        guard rc == size else { return "" }
        return fixedChars(info.pvip.vip_path)
    }

    // MARK: - Current working directory

    static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        let path = fixedChars(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    // MARK: - Mapped modules (file-backed regions)

    /// Distinct file-backed mapped images. Returns `[]` if unsupported /
    /// permission-denied. Does NOT require `task_for_pid`.
    static func modules(_ pid: pid_t) -> [ModuleInfo] {
        var address: UInt64 = 0
        var seen = Set<String>()
        var result: [ModuleInfo] = []
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)

        // Bound the walk so a pathological address space cannot spin forever.
        var iterations = 0
        while iterations < 100_000 {
            iterations += 1
            var info = proc_regionwithpathinfo()
            let rc = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, $0, size)
            }
            guard rc == size else { break }

            let regionAddr = info.prp_prinfo.pri_address
            let regionSize = info.prp_prinfo.pri_size
            let path = fixedChars(info.prp_vip.vip_path)
            if !path.isEmpty, seen.insert(path).inserted {
                let name = (path as NSString).lastPathComponent
                result.append(
                    ModuleInfo(
                        path: path,
                        name: name,
                        loadAddress: regionAddr,
                        size: regionSize,
                        isMappedFile: true
                    )
                )
            }

            let next = regionAddr &+ regionSize
            if next <= address { break }
            address = next
        }
        return result
    }

    // MARK: - Threads

    /// Public per-thread detail for processes macOS allows us to inspect.
    ///
    /// `PROC_PIDLISTTHREADS` returns 64-bit thread handles that can be passed
    /// back to `PROC_PIDTHREADINFO`. Unlike fd listing, a nil buffer does not
    /// report the required size, so callers provide the current task thread
    /// count from `PROC_PIDTASKINFO` and we over-allocate slightly for races.
    static func threads(_ pid: pid_t, expectedCount: Int) -> [ThreadInfo] {
        let capacity = max(1, expectedCount + 8)
        var threadIDs = [UInt64](repeating: 0, count: capacity)
        let listBytes = Int32(threadIDs.count * MemoryLayout<UInt64>.stride)
        let got = threadIDs.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, raw.baseAddress, listBytes)
        }
        guard got > 0 else { return [] }

        let count = min(capacity, Int(got) / MemoryLayout<UInt64>.stride)
        let infoSize = Int32(MemoryLayout<proc_threadinfo>.size)
        var result: [ThreadInfo] = []
        result.reserveCapacity(count)

        for threadID in threadIDs.prefix(count) where threadID != 0 {
            var info = proc_threadinfo()
            let rc = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTHREADINFO, threadID, $0, infoSize)
            }
            guard rc == infoSize else { continue }

            result.append(
                ThreadInfo(
                    id: threadID,
                    cpuPercent: Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100.0,
                    cpuTime: info.pth_user_time &+ info.pth_system_time,
                    state: threadStateString(info.pth_run_state),
                    startAddress: nil,
                    startSymbol: nil,
                    basePriority: info.pth_priority
                )
            )
        }
        return result
    }

    static func threadStateString(_ runState: Int32) -> String {
        switch runState {
        case TH_STATE_RUNNING:         return "running"
        case TH_STATE_STOPPED:         return "stopped"
        case TH_STATE_WAITING:         return "waiting"
        case TH_STATE_UNINTERRUPTIBLE: return "uninterruptible"
        case TH_STATE_HALTED:          return "halted"
        default:                       return "unknown"
        }
    }

    // MARK: - argv / envp via KERN_PROCARGS2

    struct ProcArgs {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Parse `KERN_PROCARGS2` for a process. Works for the current user's own
    /// processes (and any process when run as root). Returns `nil` on failure
    /// (typically permission denied for other users' processes).
    static func procArgs(_ pid: pid_t) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size < MemoryLayout<Int32>.size {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 {
            return nil
        }
        buffer = Array(buffer.prefix(size))
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }

        // argc is the first 32-bit little-endian integer.
        let argc = Int(buffer[0]) | (Int(buffer[1]) << 8)
            | (Int(buffer[2]) << 16) | (Int(buffer[3]) << 24)

        var i = MemoryLayout<Int32>.size

        func readCString() -> String {
            let start = i
            while i < buffer.count, buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            i += 1 // skip NUL
            return s
        }

        // The executable path (skipped) followed by alignment NULs.
        _ = readCString()
        while i < buffer.count, buffer[i] == 0 { i += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(max(0, argc))
        var read = 0
        while read < argc, i < buffer.count {
            arguments.append(readCString())
            read += 1
        }

        var environment: [String: String] = [:]
        while i < buffer.count, buffer[i] != 0 {
            let entry = readCString()
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                environment[key] = value
            }
        }

        return ProcArgs(arguments: arguments, environment: environment)
    }

    // MARK: - ASCII strings from an on-disk executable

    static func strings(atPath path: String, limit: Int = 8 * 1024 * 1024, minLength: Int = 4) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: limit)) ?? Data()
        } else {
            data = handle.readData(ofLength: limit)
        }
        guard !data.isEmpty else { return [] }

        var result: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(64)
        for byte in data {
            if byte >= 0x20, byte < 0x7f {
                current.append(byte)
            } else {
                if current.count >= minLength {
                    result.append(String(decoding: current, as: UTF8.self))
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= minLength {
            result.append(String(decoding: current, as: UTF8.self))
        }
        return result
    }

    // MARK: - Host / system

    static func physicalMemory() -> UInt64 {
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctl(&mib, 2, &mem, &size, nil, 0) != 0 { return 0 }
        return mem
    }

    static func userName(for uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let namePtr = pw.pointee.pw_name else { return nil }
        return String(cString: namePtr)
    }
}
