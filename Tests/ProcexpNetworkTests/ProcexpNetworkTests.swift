import Testing
import Darwin
import ProcexpModel
@testable import ProcexpNetwork

@Suite("W9 Network + GPU")
struct ProcexpNetworkTests {

    @Test("Enumerates sockets for the current process without throwing")
    func enumeratesSockets() async throws {
        let provider = NetworkProvider()
        let sockets = try await provider.sockets(of: ProcessID(pid: getpid(), startTime: 0))
        for s in sockets { #expect(!s.localAddress.isEmpty) }
    }

    @Test("Finds a known listening TCP socket in the current process")
    func findsKnownListeningSocket() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, ptr, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        let listenResult = listen(fd, 1)
        #expect(listenResult == 0)

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &boundLength)
            }
        }
        #expect(nameResult == 0)

        let port = UInt16(bigEndian: bound.sin_port)
        let sockets = try await NetworkProvider().sockets(of: ProcessID(pid: getpid(), startTime: 0))
        #expect(sockets.contains { socket in
            socket.proto == .tcp4
                && socket.localPort == port
                && socket.state == "LISTEN"
        })
    }

    @Test("Network rates are intentionally empty on macOS")
    func networkRatesEmpty() async {
        let rates = await NetworkProvider().networkRates()
        #expect(rates.isEmpty)
    }

    @Test("GPU utilization query returns a value or nil without crashing")
    func gpuQuery() async {
        let pct = await GPUStatsProvider().systemGPUPercent()
        if let pct { #expect(pct >= 0 && pct <= 100) }
    }
}
