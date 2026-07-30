//
//  main.swift
//  ProcexpHelper — W2 (privileged root daemon)
//
//  Entry point for the SMAppService-managed root daemon. It stands up a mach
//  `NSXPCListener`, validates each connecting peer's code signature, and vends
//  a `HelperService` implementing `ProcexpHelperProtocol`. Then it parks on the
//  dispatch main queue so launchd can keep it alive on demand.
//
//  NOTE: This daemon is code-complete but not expected to actually launch until
//  the app (and this helper) are Developer-ID signed and embedded per
//  `Helper/README.md` (W13). Registration via `SMAppService` fails cleanly
//  under ad-hoc signing; nothing here is exercised in that state.
//

import Foundation
import ProcexpPrivileged
import os

private let log = Logger(subsystem: HelperConstants.machServiceName, category: "main")

/// Accepts and configures incoming XPC connections after peer validation.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard PeerValidation.isTrusted(newConnection) else {
            log.error("rejected untrusted connection from pid \(newConnection.processIdentifier)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: ProcexpHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
log.info("ProcexpHelper listening on \(HelperConstants.machServiceName, privacy: .public)")

// Park forever; launchd owns our lifecycle.
dispatchMain()
