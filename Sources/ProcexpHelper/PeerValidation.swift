//
//  PeerValidation.swift
//  ProcexpHelper — W2 (privileged root daemon)
//
//  Verify the code-signing identity of a connecting XPC peer before serving it.
//  A root daemon that hands out `task_for_pid`-level data must not answer just
//  any client, so each new connection is validated here.
//
//  Under the current ad-hoc ("Sign to Run Locally") signature there is no
//  Team ID / Developer-ID anchor to pin against, so validation is intentionally
//  *lenient but present*: it obtains the peer's dynamic code object, runs
//  `SecCodeCheckValidity`, logs the outcome, and — while unsigned — allows the
//  connection. W13 (Developer-ID signing) tightens this into a hard
//  `SecRequirement` match (see `Helper/README.md`).
//

import Foundation
import Security
import os

enum PeerValidation {

    private static let log = Logger(
        subsystem: "com.sysinternals.procexpmac.helper",
        category: "peer"
    )

    /// Decide whether to accept `connection`. Returns `true` to serve it.
    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        // Resolve the peer's dynamic code object from its pid. (Audit-token
        // pinning via `kSecGuestAttributeAudit` is the hardened form and a W13
        // item; pid keying is used here because the audit_token_t accessor on
        // NSXPCConnection is SPI.)
        var code: SecCode?
        let attributes: [CFString: Any] = [kSecGuestAttributePid: pid]
        let copyStatus = SecCodeCopyGuestWithAttributes(
            nil, attributes as CFDictionary, SecCSFlags(rawValue: 0), &code
        )
        guard copyStatus == errSecSuccess, let code else {
            log.error("peer pid \(pid): SecCodeCopyGuestWithAttributes failed (\(copyStatus)); allowing under ad-hoc")
            return lenientAllow(pid: pid)
        }

        // Validate the peer's signature is intact.
        let checkStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        if checkStatus != errSecSuccess {
            log.error("peer pid \(pid): SecCodeCheckValidity failed (\(checkStatus)); allowing under ad-hoc")
            return lenientAllow(pid: pid)
        }

        // W13: additionally require a pinned identity, e.g.
        //   let req: SecRequirement = ... anchor apple generic and
        //     identifier "com.sysinternals.procexpmac" and
        //     certificate leaf[subject.OU] = "<TEAMID>"
        //   guard SecCodeCheckValidityWithErrors(code, [], req, nil) == errSecSuccess
        //   else { return false }
        log.info("peer pid \(pid): signature valid; accepted")
        return true
    }

    /// Placeholder for the lenient (ad-hoc) allow decision so the policy is in
    /// exactly one place and easy to flip to `false` once signing lands.
    private static func lenientAllow(pid: pid_t) -> Bool {
        true
    }
}
