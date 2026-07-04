import Testing
import ProcexpModel
@testable import ProcexpSigning

@Suite("W7 CodeSignProvider")
struct ProcexpSigningTests {

    @Test("Recognizes a signed platform binary")
    func signsPlatformBinary() async {
        let sig = await CodeSignProvider().signature(forPath: "/bin/ls")
        #expect(sig.status == .signed)
        #expect(sig.isPlatformBinary)
        #expect(sig.sha256 != nil)
        #expect(sig.sha256?.count == 64)
    }

    @Test("Reports non-signed for a non-existent path without crashing")
    func handlesMissingPath() async {
        let sig = await CodeSignProvider().signature(forPath: "/no/such/binary/here")
        #expect(sig.status != .signed)
    }
}
