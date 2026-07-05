import Darwin
import Foundation

setbuf(stdout, nil)
signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

private let duration = parseDuration(arguments: CommandLine.arguments)
private let remoteTarget = parseRemoteTarget(arguments: CommandLine.arguments)
private let namedThread = startNamedFixtureThread(duration: duration)

let listenFD = checkedSocket()
let clientFD = checkedSocket()
private var remoteConnection: RemoteConnection?
var acceptedFD: Int32 = -1

defer {
    _ = pthread_join(namedThread, nil)
    close(listenFD)
    close(clientFD)
    if let remoteConnection { close(remoteConnection.fd) }
    if acceptedFD >= 0 { close(acceptedFD) }
}

var reuse: Int32 = 1
_ = withUnsafePointer(to: &reuse) { ptr in
    setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, ptr, socklen_t(MemoryLayout<Int32>.size))
}

var listenAddress = sockaddr_in()
listenAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
listenAddress.sin_family = sa_family_t(AF_INET)
listenAddress.sin_port = 0
listenAddress.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

let bindResult = withUnsafePointer(to: &listenAddress) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0 else { fail("bind failed: \(lastErrno())") }
guard listen(listenFD, 4) == 0 else { fail("listen failed: \(lastErrno())") }

var boundAddress = sockaddr_in()
var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
let nameResult = withUnsafeMutablePointer(to: &boundAddress) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        getsockname(listenFD, sockaddrPtr, &boundLength)
    }
}
guard nameResult == 0 else { fail("getsockname failed: \(lastErrno())") }

let port = UInt16(bigEndian: boundAddress.sin_port)
var connectAddress = boundAddress
let connectResult = withUnsafePointer(to: &connectAddress) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(clientFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard connectResult == 0 else { fail("connect failed: \(lastErrno())") }

acceptedFD = accept(listenFD, nil, nil)
guard acceptedFD >= 0 else { fail("accept failed: \(lastErrno())") }

if let remoteTarget {
    remoteConnection = connectRemote(host: remoteTarget.host, port: remoteTarget.port)
}

print("PROCEXPMAC_TCP_FIXTURE PID \(getpid())")
print("PROCEXPMAC_TCP_FIXTURE PORT \(port)")
if let remoteTarget, let remoteConnection {
    print("PROCEXPMAC_TCP_FIXTURE REMOTE_HOST \(remoteTarget.host)")
    print("PROCEXPMAC_TCP_FIXTURE REMOTE_PORT \(remoteTarget.port)")
    print("PROCEXPMAC_TCP_FIXTURE REMOTE_ENDPOINT \(remoteConnection.endpoint)")
}
print("PROCEXPMAC_TCP_FIXTURE READY")

let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    sleep(1)
}

private func checkedSocket() -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket failed: \(lastErrno())") }
    return fd
}

private func startNamedFixtureThread(duration: TimeInterval) -> pthread_t {
    final class ThreadContext {
        let duration: TimeInterval
        init(duration: TimeInterval) { self.duration = duration }
    }

    let context = Unmanaged.passRetained(ThreadContext(duration: duration))
    var thread = pthread_t(bitPattern: 0)
    let result = pthread_create(&thread, nil, { rawContext in
        let context = Unmanaged<ThreadContext>.fromOpaque(rawContext).takeRetainedValue()
        pthread_setname_np("ProcexpTcpFixture")
        let deadline = Date().addingTimeInterval(context.duration)
        while Date() < deadline {
            sleep(1)
        }
        return nil
    }, context.toOpaque())
    guard result == 0, let thread else {
        context.release()
        fail("pthread_create failed: \(String(cString: strerror(result)))")
    }
    return thread
}

private struct RemoteTarget {
    let host: String
    let port: String
}

private struct RemoteConnection {
    let fd: Int32
    let endpoint: String
}

private func parseDuration(arguments: [String]) -> TimeInterval {
    guard let index = arguments.firstIndex(of: "--duration"), arguments.indices.contains(index + 1),
          let seconds = TimeInterval(arguments[index + 1]), seconds > 0 else {
        return 120
    }
    return seconds
}

private func parseRemoteTarget(arguments: [String]) -> RemoteTarget? {
    guard let hostIndex = arguments.firstIndex(of: "--remote-host"),
          arguments.indices.contains(hostIndex + 1) else {
        return nil
    }
    let host = arguments[hostIndex + 1]
    guard !host.isEmpty else { return nil }
    let port: String
    if let portIndex = arguments.firstIndex(of: "--remote-port"), arguments.indices.contains(portIndex + 1) {
        port = arguments[portIndex + 1]
    } else {
        port = "443"
    }
    return RemoteTarget(host: host, port: port)
}

private func connectRemote(host: String, port: String) -> RemoteConnection {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    hints.ai_family = AF_UNSPEC

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, port, &hints, &result)
    guard status == 0, let first = result else {
        fail("getaddrinfo(\(host), \(port)) failed: \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(first) }

    var cursor: UnsafeMutablePointer<addrinfo>? = first
    var lastError = "no addresses returned"
    while let info = cursor {
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                return RemoteConnection(fd: fd, endpoint: endpointDescription(info.pointee.ai_addr, length: info.pointee.ai_addrlen))
            }
            lastError = lastErrno()
            close(fd)
        } else {
            lastError = lastErrno()
        }
        cursor = info.pointee.ai_next
    }

    fail("remote connect to \(host):\(port) failed: \(lastError)")
}

private func endpointDescription(_ address: UnsafePointer<sockaddr>?, length: socklen_t) -> String {
    guard let address else { return "" }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
    let flags = NI_NUMERICHOST | NI_NUMERICSERV
    let status = getnameinfo(address, length, &host, socklen_t(host.count), &service, socklen_t(service.count), flags)
    guard status == 0 else { return "" }
    return "\(String(cString: host)):\(String(cString: service))"
}

private func lastErrno() -> String {
    String(cString: strerror(errno))
}

private func fail(_ message: String) -> Never {
    fputs("PROCEXPMAC_TCP_FIXTURE ERROR \(message)\n", stderr)
    exit(1)
}