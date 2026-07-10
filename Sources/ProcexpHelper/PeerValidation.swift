//
//  PeerValidation.swift
//  ProcexpHelper — W2 (privileged root daemon)
//
//  Verify the code-signing identity of a connecting XPC peer before serving it.
//  A root daemon that hands out `task_for_pid`-level data must not answer just
//  any client, so each new connection is validated here.
//
//  Debug builds accept any peer with an intact signature so local ad-hoc
//  development remains possible. Release builds additionally require the
//  official app identifier and Microsoft Developer ID Team ID.
//

import Foundation
import Security
import os

enum PeerValidation {

    private static let officialAppIdentifier = "com.sysinternals.procexpmac"

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
            log.error("peer pid \(pid): SecCodeCopyGuestWithAttributes failed (\(copyStatus)); rejected")
            return false
        }

        // Validate the peer's signature is intact.
        let checkStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        if checkStatus != errSecSuccess {
            log.error("peer pid \(pid): SecCodeCheckValidity failed (\(checkStatus)); rejected")
            return false
        }

        #if DEBUG
        log.notice("peer pid \(pid): accepting intact ad-hoc signature in DEBUG build")
        return true
        #else
        guard let teamIdentifier = ownTeamIdentifier() else {
            log.fault("could not determine helper Team ID; rejecting pid \(pid)")
            return false
        }

        let requirementText = "anchor apple generic and identifier \"\(officialAppIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            log.fault("could not create official peer requirement (\(requirementStatus)); rejecting pid \(pid)")
            return false
        }

        let identityStatus = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: 0),
            requirement
        )
        guard identityStatus == errSecSuccess else {
            log.error("peer pid \(pid): official identity requirement failed (\(identityStatus)); rejected")
            return false
        }

        log.info("peer pid \(pid): official identity requirement passed; accepted")
        return true
        #endif
    }

    /// Return the Team ID from this helper's own code signature. The app must
    /// be signed by the same team, avoiding a duplicated identity constant.
    private static func ownTeamIdentifier() -> String? {
        var ownCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &ownCode) == errSecSuccess,
              let ownCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            ownCode,
            SecCSFlags(rawValue: 0),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else {
            return nil
        }

        return information[kSecCodeInfoTeamIdentifier] as? String
    }
}
