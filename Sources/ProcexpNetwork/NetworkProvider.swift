//
//  NetworkProvider.swift
//  ProcexpNetwork — W9
//
//  Per-process socket enumeration via libproc:
//    proc_pidinfo(PROC_PIDLISTFDS)   -> list of fds
//    proc_pidfdinfo(PROC_PIDFDSOCKETINFO) -> socket_fdinfo per socket fd
//
//  The C structures in <sys/proc_info.h> (socket_fdinfo, socket_info,
//  in_sockinfo, tcp_sockinfo) contain nested unions. Clang imports each C
//  union into Swift as a struct exposing every member as a computed property,
//  so `psi.soi_proto.pri_tcp` and `insi_laddr.ina_46.i46a_addr4` are reachable
//  directly without manual reinterpretation.
//

import Foundation
import Darwin
import ProcexpModel

/// Best-effort per-process networking source for macOS.
///
/// A stateless value: no stored mutable state, so it is trivially `Sendable`.
public final class NetworkProvider: NetworkProviding {

    public init() {}

    // MARK: - Sockets

    public func sockets(of id: ProcessID) async throws -> [SocketInfo] {
        let pid = id.pid

        // 1) Size the fd list. A dead/exited process simply yields <= 0 here.
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(listSize) / stride
        guard capacity > 0 else { return [] }

        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = fds.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return [] }

        let actualCount = min(capacity, Int(used) / stride)
        var results: [SocketInfo] = []
        results.reserveCapacity(actualCount)

        // 2) For every socket fd, pull its socket_info and decode it.
        for index in 0..<actualCount {
            let entry = fds[index]
            guard entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            if let info = Self.socketInfo(pid: pid, fd: entry.proc_fd) {
                results.append(info)
            }
            // Any fd that fails (raced with close, permission, kind we don't
            // model) is silently skipped — never fatal.
        }

        return results
    }

    /// Decode a single socket fd into a `SocketInfo`, or `nil` if it is not an
    /// IPv4/IPv6 TCP/UDP endpoint or the query failed.
    private static func socketInfo(pid: Int32, fd: Int32) -> SocketInfo? {
        var sock = socket_fdinfo()
        let want = Int32(MemoryLayout<socket_fdinfo>.stride)
        let got = withUnsafeMutablePointer(to: &sock) { ptr -> Int32 in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ptr, want)
        }
        // proc_pidfdinfo returns the number of bytes written; require at least
        // the fixed-size socket_info to have landed.
        guard got >= Int32(MemoryLayout<socket_info>.size) else { return nil }

        let psi = sock.psi

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
                state: tcpStateString(tcp.tcpsi_state)
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
                state: ""            // UDP / raw IN sockets are stateless.
            )

        default:
            // UNIX-domain, ndrv, kernel-event, kernel-ctl, generic: not network.
            return nil
        }
    }

    // MARK: - in_sockinfo decoding

    /// Extract (proto, localAddr, localPort, remoteAddr, remotePort) from an
    /// `in_sockinfo`. `tcp` selects the tcp4/tcp6 vs udp4/udp6 family.
    private static func decode(
        _ ini: in_sockinfo,
        tcp: Bool
    ) -> (SocketProto, String, UInt16, String, UInt16)? {
        let lport = hostPort(ini.insi_lport)
        let fport = hostPort(ini.insi_fport)

        // insi_vflag carries INI_IPV4 (0x1) / INI_IPV6 (0x2).
        let vflag = ini.insi_vflag
        if vflag & UInt8(INI_IPV4) != 0 {
            var lin = ini.insi_laddr.ina_46.i46a_addr4
            var fin = ini.insi_faddr.ina_46.i46a_addr4
            let laddr = formatIPv4(&lin)
            let faddr = formatIPv4(&fin)
            return (tcp ? .tcp4 : .udp4, laddr, lport, faddr, fport)
        } else if vflag & UInt8(INI_IPV6) != 0 {
            var lin6 = ini.insi_laddr.ina_6
            var fin6 = ini.insi_faddr.ina_6
            let laddr = formatIPv6(&lin6)
            let faddr = formatIPv6(&fin6)
            return (tcp ? .tcp6 : .udp6, laddr, lport, faddr, fport)
        }
        return nil
    }

    /// Ports in `in_sockinfo` are stored in network byte order within an int;
    /// reinterpret the low 16 bits as big-endian to get the host-order port.
    private static func hostPort(_ raw: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
    }

    private static func formatIPv4(_ addr: inout in_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: buf)
    }

    private static func formatIPv6(_ addr: inout in6_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: buf)
    }

    /// Map the TCP FSM state (`tcpsi_state`, values from <netinet/tcp_fsm.h>) to
    /// a human-readable label matching common tooling (netstat/lsof).
    private static func tcpStateString(_ state: Int32) -> String {
        switch state {
        case 0:  return "CLOSED"
        case 1:  return "LISTEN"
        case 2:  return "SYN_SENT"
        case 3:  return "SYN_RECEIVED"
        case 4:  return "ESTABLISHED"
        case 5:  return "CLOSE_WAIT"
        case 6:  return "FIN_WAIT_1"
        case 7:  return "CLOSING"
        case 8:  return "LAST_ACK"
        case 9:  return "FIN_WAIT_2"
        case 10: return "TIME_WAIT"
        default: return ""
        }
    }

    // MARK: - Network rates

    /// Per-process network byte-rate accounting is **not available** on macOS
    /// through any public API.
    ///
    /// The kernel does not surface per-PID interface counters; the only
    /// mechanisms that expose them are private (the `NetworkStatistics`
    /// framework / `ntstat` PF_SYSTEM control that `nettop` uses, and the
    /// private `libnetcore`). Those are not part of a supportable, notarizable
    /// app, and this task explicitly forbids shelling out to `nettop`.
    ///
    /// We therefore return an empty dictionary. The UI treats a missing entry
    /// as "unknown" and leaves the network-rate column blank rather than
    /// showing a fabricated value.
    public func networkRates() async -> [ProcessID: UInt64] {
        [:]
    }
}
