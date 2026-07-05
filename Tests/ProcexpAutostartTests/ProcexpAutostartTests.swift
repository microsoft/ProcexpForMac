import Testing
import Foundation
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

    @Test("Login item heuristic is limited to Applications app bundles")
    func loginItemHeuristicScope() {
        #expect(AutostartProvider.looksLikeLoginItemCandidate("/Applications/Foo.app/Contents/MacOS/Foo"))
        let userApp = NSHomeDirectory() + "/Applications/Foo.app/Contents/MacOS/Foo"
        #expect(AutostartProvider.looksLikeLoginItemCandidate(userApp))
        #expect(!AutostartProvider.looksLikeLoginItemCandidate("/usr/bin/foo"))
        #expect(!AutostartProvider.looksLikeLoginItemCandidate("/tmp/Foo.app/Contents/MacOS/Foo"))
    }
}
