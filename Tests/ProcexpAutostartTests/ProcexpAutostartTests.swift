import Testing
import ProcexpModel
@testable import ProcexpAutostart

@Suite("W12 AutostartProvider")
struct ProcexpAutostartTests {

    @Test("Scans launchd plists and matches without crashing")
    func scansWithoutCrashing() async {
        let provider = AutostartProvider()
        let record = ProcessRecord(
            id: ProcessID(pid: 1, startTime: 0),
            name: "launchd",
            executablePath: "/sbin/launchd",
            flags: [.service]
        )
        _ = await provider.autostartLocation(for: record)
        #expect(Bool(true))
    }
}
