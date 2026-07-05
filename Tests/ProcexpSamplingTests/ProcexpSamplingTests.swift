import Testing
import Darwin
import Foundation
import ProcexpModel
@testable import ProcexpSampling

@Suite("W1 LibprocDataProvider")
struct ProcexpSamplingTests {

    @Test("Samples the real process list")
    func samplesRealProcesses() async {
        let provider = LibprocDataProvider()
        let snap = await provider.snapshot()
        #expect(snap.processes.count > 20)
        #expect(snap.processes.keys.contains { $0.pid == 1 }) // launchd
    }

    @Test("Flags the current process as own")
    func flagsOwnProcess() async {
        let provider = LibprocDataProvider()
        let snap = await provider.snapshot()
        let me = snap.processes.values.first { $0.id.pid == getpid() }
        #expect(me != nil)
        #expect(me?.flags.contains(.ownProcess) == true)
        #expect((me?.threadCount ?? 0) > 0)
    }

    @Test("Reads public thread detail for the current process")
    func readsThreadDetailForCurrentProcess() throws {
        let taskInfo = try #require(Libproc.taskInfo(getpid()))
        let threads = Libproc.threads(getpid(), expectedCount: Int(taskInfo.pti_threadnum))

        #expect(!threads.isEmpty)
        #expect(threads.contains { !$0.state.isEmpty && $0.state != "unknown" })
        #expect(threads.contains { $0.basePriority > 0 })
        #expect(threads.contains { $0.currentPriority > 0 })
        #expect(threads.allSatisfy { $0.cpuTime == $0.userTime + $0.kernelTime })
        #expect(threads.allSatisfy { $0.sleepTimeSeconds >= 0 })
        #expect(threads.allSatisfy { $0.dispatchQueueAddress == nil })
    }

    @Test("Reads public thread names")
    func readsPublicThreadNames() throws {
        final class NamedThreadContext {
            let ready = DispatchSemaphore(value: 0)
            let stop = DispatchSemaphore(value: 0)
        }

        let context = Unmanaged.passRetained(NamedThreadContext())
        var thread = pthread_t(bitPattern: 0)
        let result = pthread_create(&thread, nil, { rawContext in
            let context = Unmanaged<NamedThreadContext>.fromOpaque(rawContext).takeUnretainedValue()
            pthread_setname_np("ProcexpThreadTest")
            context.ready.signal()
            _ = context.stop.wait(timeout: .now() + .seconds(10))
            return nil
        }, context.toOpaque())
        #expect(result == 0)
        let retainedContext = context.takeRetainedValue()
        defer {
            retainedContext.stop.signal()
            if let thread { pthread_join(thread, nil) }
        }
        guard result == 0 else { return }
        _ = retainedContext.ready.wait(timeout: .now() + .seconds(2))

        let threads = Libproc.threads(getpid(), expectedCount: 16)

        #expect(threads.contains { $0.name == "ProcexpThreadTest" })
    }

    @Test("Samples extended proc taskinfo counters for current process")
    func samplesExtendedTaskInfo() async throws {
        let provider = LibprocDataProvider()
        let snap = await provider.snapshot()
        let me = try #require(snap.processes.values.first { $0.id.pid == getpid() })

        #expect(!me.flags.contains(.limitedTaskInfo))
        #expect(me.runningThreadCount != nil)
        #expect(me.pageIns != nil)
        #expect(me.copyOnWriteFaults != nil)
        #expect(me.machSyscalls != nil)
        #expect(me.unixSyscalls != nil)
        #expect(me.threadUserTime != nil)
        #expect(me.threadSystemTime != nil)
        #expect(me.taskPolicy != nil)
        #expect(me.bsdFlagsRaw != nil)
        #expect(me.bsdStatusRaw != nil)
    }

    @Test("Reads vnode metadata for an open temp-file descriptor")
    func readsVnodeMetadataForOpenFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("procexpmac-fd-")
            .appendingPathExtension(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(repeating: 0x41, count: 12))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fd = open(tempURL.path, O_RDONLY)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        _ = lseek(fd, 4, SEEK_SET)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let provider = LibprocDataProvider()
        let snap = await provider.snapshot()
        let me = try #require(snap.processes.values.first { $0.id.pid == getpid() })
        let descriptors = try await provider.fileDescriptors(of: me.id)
        let descriptor = try #require(descriptors.first { $0.id == fd })

        #expect(descriptor.kind == .vnode)
        #expect(descriptor.name.hasSuffix(tempURL.lastPathComponent))
        #expect(descriptor.offset == 4)
        #expect((descriptor.statusFlags ?? 0) & UInt32(PROC_FP_CLEXEC) != 0)
        #expect(descriptor.vnode?.type == .regular)
        #expect(descriptor.vnode?.inode != 0)
        #expect(descriptor.vnode?.size == 12)
    }

    @Test("Advertises accurate-CPU capability")
    func capabilities() {
        #expect(LibprocDataProvider().capabilities.contains(.accurateCPU))
    }
}
