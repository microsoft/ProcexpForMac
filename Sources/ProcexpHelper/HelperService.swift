//
//  HelperService.swift
//  ProcexpHelper — W2 (privileged root daemon)
//
//  The `ProcexpHelperProtocol` implementation the daemon exports over XPC.
//
//  Most methods delegate to the *public* API of `LibprocDataProvider` (W1):
//  running as root, the same libproc/sysctl calls that are permission-limited
//  for a normal user return data for *every* process (cross-user argv/env/cwd,
//  full descriptor and module lists, SIP-protected detail). The one thing
//  libproc cannot do — real per-thread CPU/state — is added here via
//  `ThreadSampler` (`task_for_pid`).
//

import Foundation
import Darwin
import ProcexpModel
import ProcexpSampling
import ProcexpPrivileged

final class HelperService: NSObject, ProcexpHelperProtocol {

    private let provider = LibprocDataProvider()

    // MARK: - Snapshot

    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void) {
        let provider = self.provider
        Task {
            let snap = await provider.snapshot()
            Self.encodeReply(ProcessSnapshotDTO(snap), reply)
        }
    }

    // MARK: - Threads (privileged task_for_pid path)

    func threads(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) {
        // Prefer real per-thread detail from the task port.
        if let dtos = ThreadSampler.threads(pid: pid) {
            Self.encodeReply(dtos, reply)
            return
        }
        // Fall back to the unprivileged count-only stubs when the task port is
        // unobtainable (e.g. task_for_pid denied to root under ad-hoc signing).
        let provider = self.provider
        Task {
            do {
                let stubs = try await provider.threads(of: ProcessID(pid: pid, startTime: startTime))
                Self.encodeReply(stubs.map(ThreadInfoDTO.init), reply)
            } catch {
                reply(nil, Self.map(error))
            }
        }
    }

    // MARK: - Detail (delegated; root => cross-user)

    func modules(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do {
                let mods = try await provider.modules(of: ProcessID(pid: pid, startTime: startTime))
                Self.encodeReply(mods.map(ModuleInfoDTO.init), reply)
            } catch { reply(nil, Self.map(error)) }
        }
    }

    func fileDescriptors(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do {
                let fds = try await provider.fileDescriptors(of: ProcessID(pid: pid, startTime: startTime))
                Self.encodeReply(fds.map(FileDescriptorInfoDTO.init), reply)
            } catch { reply(nil, Self.map(error)) }
        }
    }

    func commandLine(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do { reply(try await provider.commandLine(of: ProcessID(pid: pid, startTime: 0)), nil) }
            catch { reply(nil, Self.map(error)) }
        }
    }

    func environment(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do {
                let env = try await provider.environment(of: ProcessID(pid: pid, startTime: 0))
                Self.encodeReply(env, reply)
            } catch { reply(nil, Self.map(error)) }
        }
    }

    func currentDirectory(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do { reply(try await provider.currentDirectory(of: ProcessID(pid: pid, startTime: 0)), nil) }
            catch { reply(nil, Self.map(error)) }
        }
    }

    func strings(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void) {
        let provider = self.provider
        Task {
            do {
                let strings = try await provider.strings(of: ProcessID(pid: pid, startTime: 0))
                Self.encodeReply(strings, reply)
            } catch { reply(nil, Self.map(error)) }
        }
    }

    // MARK: - Actions (root => any process)

    func sendSignal(pid: Int32, signal: Int32, withReply reply: @escaping (Error?) -> Void) {
        if Darwin.kill(pid, signal) != 0 {
            reply(Self.errnoError(errno))
        } else {
            reply(nil)
        }
    }

    func setNice(pid: Int32, nice: Int32, withReply reply: @escaping (Error?) -> Void) {
        errno = 0
        let rc = setpriority(PRIO_PROCESS, id_t(pid), nice)
        if rc == -1 && errno != 0 {
            reply(Self.errnoError(errno))
        } else {
            reply(nil)
        }
    }

    // MARK: - Encoding / error mapping

    private static func encodeReply<T: Encodable>(_ value: T, _ reply: (Data?, Error?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, HelperError.make(.underlying, "encode failed: \(error.localizedDescription)"))
        }
    }

    /// Map a `ProviderError` thrown by `LibprocDataProvider` to an `NSError`.
    private static func map(_ error: Error) -> NSError {
        switch error {
        case ProviderError.notPermitted: return HelperError.make(.notPermitted, "operation not permitted")
        case ProviderError.processGone:  return HelperError.make(.processGone, "process no longer exists")
        case ProviderError.unsupported:  return HelperError.make(.unsupported, "operation not supported")
        case ProviderError.helperUnavailable:
            return HelperError.make(.underlying, "helper unavailable")
        case ProviderError.underlying(let message):
            return HelperError.make(.underlying, message)
        default:
            return HelperError.make(.underlying, error.localizedDescription)
        }
    }

    private static func errnoError(_ err: Int32) -> NSError {
        switch err {
        case EPERM, EACCES: return HelperError.make(.notPermitted, "operation not permitted")
        case ESRCH:         return HelperError.make(.processGone, "process no longer exists")
        default:            return HelperError.make(.underlying, String(cString: strerror(err)))
        }
    }
}
