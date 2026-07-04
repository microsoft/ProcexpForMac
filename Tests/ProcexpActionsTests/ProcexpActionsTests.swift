import Testing
import ProcexpModel
@testable import ProcexpActions

@Suite("W8 ProcessActions")
struct ProcexpActionsTests {

    @Test("Destructive actions require confirmation")
    func destructiveActionsConfirm() {
        #expect(ActionConfirmation.forKind(.kill, processName: "demo").requiresConfirmation)
        #expect(ActionConfirmation.forKind(.killTree, processName: "demo").requiresConfirmation)
    }

    @Test("Non-destructive actions do not require confirmation")
    func nonDestructiveNoConfirm() {
        #expect(!ActionConfirmation.forKind(.resume, processName: "demo").requiresConfirmation)
    }
}
