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

    struct TaskInfoDetails {
        var cpuTime: UInt64 = 0
        var threadCount: Int = 0
        var runningThreadCount: Int? = nil
        var threadUserTime: UInt64? = nil
        var threadSystemTime: UInt64? = nil
        var taskPolicy: Int32? = nil
        var residentSize: UInt64 = 0
        var virtualSize: UInt64 = 0
        var pageFaults: UInt64? = nil
        var pageIns: UInt64? = nil
        var copyOnWriteFaults: UInt64? = nil
        var machMessagesSent: UInt64? = nil
        var machMessagesReceived: UInt64? = nil
        var machSyscalls: UInt64? = nil
        var unixSyscalls: UInt64? = nil
        var contextSwitches: UInt64? = nil
        var priority: Int32 = 0
    }

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

    @inline(__always)
    static func unsignedCounter(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
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

    static func taskDetails(_ info: proc_taskinfo) -> TaskInfoDetails {
        TaskInfoDetails(
            cpuTime: info.pti_total_user &+ info.pti_total_system,
            threadCount: Int(info.pti_threadnum),
            runningThreadCount: Int(info.pti_numrunning),
            threadUserTime: info.pti_threads_user,
            threadSystemTime: info.pti_threads_system,
            taskPolicy: info.pti_policy,
            residentSize: info.pti_resident_size,
            virtualSize: info.pti_virtual_size,
            pageFaults: unsignedCounter(info.pti_faults),
            pageIns: unsignedCounter(info.pti_pageins),
            copyOnWriteFaults: unsignedCounter(info.pti_cow_faults),
            machMessagesSent: unsignedCounter(info.pti_messages_sent),
            machMessagesReceived: unsignedCounter(info.pti_messages_received),
            machSyscalls: unsignedCounter(info.pti_syscalls_mach),
            unixSyscalls: unsignedCounter(info.pti_syscalls_unix),
            contextSwitches: unsignedCounter(info.pti_csw),
            priority: info.pti_priority
        )
    }

    static func sessionTTY(device: UInt32, hasControllingTTY: Bool) -> String? {
        guard hasControllingTTY, device != UInt32(bitPattern: Int32(-1)) else { return nil }
        guard let name = devname(dev_t(device), S_IFCHR) else { return nil }
        return String(cString: name)
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
            var details: FileDescriptorInfo?
            switch type {
            case PROX_FDTYPE_VNODE:
                kind = .vnode
                details = vnodeDescriptor(pid: pid, fd: fd.proc_fd)
                name = details?.name ?? ""
            case PROX_FDTYPE_SOCKET:
                kind = .socket
                details = socketDescriptor(pid: pid, fd: fd.proc_fd)
                name = details?.name ?? ""
            case PROX_FDTYPE_KQUEUE:
                kind = .kqueue
            case PROX_FDTYPE_PIPE:
                kind = .pipe
            case PROX_FDTYPE_FSEVENTS:
                kind = .fsevent
            default:
                kind = .other
            }
            result.append(details ?? FileDescriptorInfo(id: fd.proc_fd, kind: kind, name: name))
        }
        return result
    }

    private static func vnodeDescriptor(pid: pid_t, fd: Int32) -> FileDescriptorInfo? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, $0, size)
        }
        guard rc == size else { return nil }
        let stat = info.pvip.vip_vi.vi_stat
        return FileDescriptorInfo(
            id: fd,
            kind: .vnode,
            name: fixedChars(info.pvip.vip_path),
            openFlags: info.pfi.fi_openflags,
            statusFlags: info.pfi.fi_status,
            offset: Int64(info.pfi.fi_offset),
            fileInfoType: info.pfi.fi_type,
            guardFlags: info.pfi.fi_guardflags,
            vnode: vnodeInfo(stat: stat)
        )
    }

    private static func socketDescriptor(pid: pid_t, fd: Int32) -> FileDescriptorInfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, $0, size)
        }
        guard rc == size else { return nil }
        let socket = socketInfo(fd: fd, psi: info.psi)
        let name = socket.map { socketEndpoint($0) } ?? ""
        return FileDescriptorInfo(
            id: fd,
            kind: .socket,
            name: name,
            openFlags: info.pfi.fi_openflags,
            statusFlags: info.pfi.fi_status,
            offset: Int64(info.pfi.fi_offset),
            fileInfoType: info.pfi.fi_type,
            guardFlags: info.pfi.fi_guardflags,
            socket: socket
        )
    }

    static func socketInfo(fd: Int32, psi: socket_info) -> SocketInfo? {
        switch Int(psi.soi_kind) {
        case Int(SOCKINFO_TCP):
            let tcp = psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            guard let (proto, laddr, lport, faddr, fport) = decode(ini, tcp: true) else { return nil }
            return SocketInfo(
                id: fd,
                proto: proto,
                localAddress: laddr,
                localPort: lport,
                remoteAddress: faddr,
                remotePort: fport,
                state: tcpStateString(tcp.tcpsi_state),
                addressFamily: Int32(psi.soi_family),
                socketType: Int32(psi.soi_type),
                protocolNumber: Int32(psi.soi_protocol),
                socketKind: Int32(psi.soi_kind),
                socketOptions: UInt16(bitPattern: psi.soi_options),
                socketStateFlags: UInt16(bitPattern: psi.soi_state),
                linger: psi.soi_linger,
                socketTimeout: psi.soi_timeo,
                socketError: psi.soi_error,
                outOfBandMark: psi.soi_oobmark,
                queueLength: psi.soi_qlen,
                incompleteQueueLength: psi.soi_incqlen,
                queueLimit: psi.soi_qlimit,
                receiveBuffer: socketBuffer(psi.soi_rcv),
                sendBuffer: socketBuffer(psi.soi_snd),
                tcpStateRaw: Int32(tcp.tcpsi_state),
                tcpMaximumSegmentSize: Int32(tcp.tcpsi_mss),
                tcpFlags: tcp.tcpsi_flags,
                tcpTimers: tcpTimers(tcp.tcpsi_timer)
            )

        case Int(SOCKINFO_IN):
            let ini = psi.soi_proto.pri_in
            guard let (proto, laddr, lport, faddr, fport) = decode(ini, tcp: false) else { return nil }
            return SocketInfo(
                id: fd,
                proto: proto,
                localAddress: laddr,
                localPort: lport,
                remoteAddress: faddr,
                remotePort: fport,
                state: "",
                addressFamily: Int32(psi.soi_family),
                socketType: Int32(psi.soi_type),
                protocolNumber: Int32(psi.soi_protocol),
                socketKind: Int32(psi.soi_kind),
                socketOptions: UInt16(bitPattern: psi.soi_options),
                socketStateFlags: UInt16(bitPattern: psi.soi_state),
                linger: psi.soi_linger,
                socketTimeout: psi.soi_timeo,
                socketError: psi.soi_error,
                outOfBandMark: psi.soi_oobmark,
                queueLength: psi.soi_qlen,
                incompleteQueueLength: psi.soi_incqlen,
                queueLimit: psi.soi_qlimit,
                receiveBuffer: socketBuffer(psi.soi_rcv),
                sendBuffer: socketBuffer(psi.soi_snd)
            )

        default:
            return nil
        }
    }

    private static func socketEndpoint(_ socket: SocketInfo) -> String {
        let local = socket.localPort == 0 ? socket.localAddress : "\(socket.localAddress):\(socket.localPort)"
        guard socket.remotePort != 0 || !socket.remoteAddress.isEmpty else { return local }
        let remote = socket.remotePort == 0 ? socket.remoteAddress : "\(socket.remoteAddress):\(socket.remotePort)"
        return "\(local) -> \(remote)"
    }

    private static func vnodeInfo(stat: vinfo_stat) -> VnodeDescriptorInfo {
        VnodeDescriptorInfo(
            typeRaw: Int32(stat.vst_mode & UInt16(S_IFMT)),
            type: vnodeKind(mode: stat.vst_mode),
            mode: stat.vst_mode,
            deviceID: stat.vst_dev,
            specialDeviceID: stat.vst_rdev,
            inode: stat.vst_ino,
            size: Int64(stat.vst_size),
            accessTime: date(seconds: stat.vst_atime, nanos: stat.vst_atimensec),
            modificationTime: date(seconds: stat.vst_mtime, nanos: stat.vst_mtimensec),
            statusChangeTime: date(seconds: stat.vst_ctime, nanos: stat.vst_ctimensec),
            birthTime: date(seconds: stat.vst_birthtime, nanos: stat.vst_birthtimensec)
        )
    }

    private static func vnodeKind(mode: UInt16) -> VnodeKind {
        switch mode & S_IFMT {
        case S_IFREG: return .regular
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        case S_IFCHR: return .characterDevice
        case S_IFBLK: return .blockDevice
        case S_IFSOCK: return .socket
        case S_IFIFO: return .fifo
        default: return .unknown
        }
    }

    private static func date(seconds: Int64, nanos: Int64) -> Date? {
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    private static func socketBuffer(_ info: sockbuf_info) -> SocketBufferInfo {
        SocketBufferInfo(
            currentBytes: info.sbi_cc,
            highWaterMark: info.sbi_hiwat,
            mbufBytes: info.sbi_mbcnt,
            mbufLimit: info.sbi_mbmax,
            lowWaterMark: info.sbi_lowat,
            flags: info.sbi_flags,
            timeout: info.sbi_timeo
        )
    }

    private static func tcpTimers<T>(_ timers: T) -> TCPTimerInfo {
        withUnsafeBytes(of: timers) { raw in
            let values = raw.bindMemory(to: Int32.self)
            return TCPTimerInfo(
                retransmit: values.indices.contains(0) ? values[0] : 0,
                persist: values.indices.contains(1) ? values[1] : 0,
                keepAlive: values.indices.contains(2) ? values[2] : 0,
                twoMSL: values.indices.contains(3) ? values[3] : 0
            )
        }
    }

    static func decode(
        _ ini: in_sockinfo,
        tcp: Bool
    ) -> (SocketProto, String, UInt16, String, UInt16)? {
        let lport = hostPort(ini.insi_lport)
        let fport = hostPort(ini.insi_fport)

        let vflag = ini.insi_vflag
        if vflag & UInt8(INI_IPV4) != 0 {
            var lin = ini.insi_laddr.ina_46.i46a_addr4
            var fin = ini.insi_faddr.ina_46.i46a_addr4
            return (tcp ? .tcp4 : .udp4, formatIPv4(&lin), lport, formatIPv4(&fin), fport)
        } else if vflag & UInt8(INI_IPV6) != 0 {
            var lin6 = ini.insi_laddr.ina_6
            var fin6 = ini.insi_faddr.ina_6
            return (tcp ? .tcp6 : .udp6, formatIPv6(&lin6), lport, formatIPv6(&fin6), fport)
        }
        return nil
    }

    static func hostPort(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    static func formatIPv4(_ addr: inout in_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    static func formatIPv6(_ addr: inout in6_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buf)
    }

    static func tcpStateString(_ state: Int32) -> String {
        switch state {
        case 0: return "CLOSED"
        case 1: return "LISTEN"
        case 2: return "SYN_SENT"
        case 3: return "SYN_RCVD"
        case 4: return "ESTABLISHED"
        case 5: return "CLOSE_WAIT"
        case 6: return "FIN_WAIT_1"
        case 7: return "CLOSING"
        case 8: return "LAST_ACK"
        case 9: return "FIN_WAIT_2"
        case 10: return "TIME_WAIT"
        default: return String(state)
        }
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
                    name: fixedChars(info.pth_name),
                    cpuPercent: Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100.0,
                    cpuTime: info.pth_user_time &+ info.pth_system_time,
                    userTime: info.pth_user_time,
                    kernelTime: info.pth_system_time,
                    state: threadStateString(info.pth_run_state),
                    startAddress: nil,
                    startSymbol: nil,
                    currentPriority: info.pth_curpri,
                    basePriority: info.pth_priority,
                    maxPriority: info.pth_maxpriority,
                    schedulerPolicy: info.pth_policy,
                    sleepTimeSeconds: info.pth_sleep_time,
                    flags: info.pth_flags
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

    // MARK: - Printable strings from an on-disk executable

    static func strings(atPath path: String, minLength: Int = 3) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let chunkSize = 65_536 + 8
        let overlap = UInt64(max(0, minLength - 1))
        var result: [String] = []

        while true {
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { break }
            result.append(contentsOf: scanBufferForStrings(Array(data), minLength: minLength))

            if data.count == chunkSize, overlap > 0 {
                let offset = handle.offsetInFile
                handle.seek(toFileOffset: offset > overlap ? offset - overlap : 0)
            }
        }
        return result
    }

    private static func scanBufferForStrings(_ bytes: [UInt8], minLength: Int) -> [String] {
        guard bytes.count >= minLength else { return [] }
        var result: [String] = []
        result.append(contentsOf: scanUTF16Strings(in: bytes, minLength: minLength))
        result.append(contentsOf: scanASCIIStrings(in: bytes, minLength: minLength))
        return result
    }

    private static func scanUTF16Strings(in bytes: [UInt8], minLength: Int) -> [String] {
        var result: [String] = []
        var sequenceStart: Int?
        var index = 0

        while index + 1 < bytes.count {
            let low = bytes[index]
            let high = bytes[index + 1]
            if high == 0, isWindowsPrintable(low), low != 0x20 || sequenceStart != nil {
                if sequenceStart == nil { sequenceStart = index }
                index += 2
                continue
            }
            if let start = sequenceStart {
                appendUTF16String(bytes, from: start, to: index, minLength: minLength, result: &result)
                sequenceStart = nil
            }
            index += 1
        }
        if let start = sequenceStart {
            appendUTF16String(bytes, from: start, to: index, minLength: minLength, result: &result)
        }
        return result
    }

    private static func scanASCIIStrings(in bytes: [UInt8], minLength: Int) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(64)
        for byte in bytes {
            if isWindowsPrintable(byte), byte != 0x20 || !current.isEmpty {
                current.append(byte)
            } else {
                appendASCIIString(current, minLength: minLength, result: &result)
                current.removeAll(keepingCapacity: true)
            }
        }
        appendASCIIString(current, minLength: minLength, result: &result)
        return result
    }

    private static func appendUTF16String(
        _ bytes: [UInt8],
        from start: Int,
        to end: Int,
        minLength: Int,
        result: inout [String]
    ) {
        guard end - start >= minLength * 2 else { return }
        var lowBytes: [UInt8] = []
        lowBytes.reserveCapacity((end - start) / 2)
        var alphaCount = 0
        var index = start
        while index + 1 < end {
            let low = bytes[index]
            let high = bytes[index + 1]
            guard high == 0, isWindowsPrintable(low) else { break }
            if isASCIIAlpha(low) { alphaCount += 1 }
            lowBytes.append(low)
            index += 2
        }
        guard lowBytes.count >= minLength, alphaCount >= minLength else { return }
        result.append(String(decoding: lowBytes, as: UTF8.self))
    }

    private static func appendASCIIString(_ bytes: [UInt8], minLength: Int, result: inout [String]) {
        guard bytes.count >= minLength else { return }
        let alphaCount = bytes.reduce(0) { $0 + (isASCIIAlpha($1) ? 1 : 0) }
        guard alphaCount >= minLength else { return }
        result.append(String(decoding: bytes, as: UTF8.self))
    }

    private static func isWindowsPrintable(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7e
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
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
