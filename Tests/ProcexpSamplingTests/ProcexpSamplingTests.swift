import Testing
import Darwin
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
    func readsThreadDetailForCurrentProcess() async throws {
        let provider = LibprocDataProvider()
        let snap = await provider.snapshot()
        let me = try #require(snap.processes.values.first { $0.id.pid == getpid() })

        let threads = try await provider.threads(of: me.id)

        #expect(!threads.isEmpty)
        #expect(threads.contains { !$0.state.isEmpty && $0.state != "unknown" })
        #expect(threads.contains { $0.basePriority > 0 })
    }

    @Test("Advertises accurate-CPU capability")
    func capabilities() {
        #expect(LibprocDataProvider().capabilities.contains(.accurateCPU))
    }
}
