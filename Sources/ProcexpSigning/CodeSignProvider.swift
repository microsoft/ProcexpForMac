//
//  CodeSignProvider.swift
//  ProcexpSigning — W7
//
//  Real implementation of `SigningProviding`: inspects a Mach-O / bundle on
//  disk with the Security framework code-signing API and computes its SHA-256,
//  and (separately) looks up file reputation via VirusTotal.
//

import Foundation
import Security
import CryptoKit
import ProcexpModel

/// Code-signing + reputation provider (W7).
///
/// `final` + immutable, `Sendable` stored state → safely `Sendable`, as the
/// `SigningProviding` protocol requires.
public final class CodeSignProvider: SigningProviding {
    private let virusTotalClient: VirusTotalClient

    public init() {
        // The client reads the API key from the Keychain each time it needs it,
        // so a key set later via `setAPIKey` takes effect without re-creating.
        self.virusTotalClient = VirusTotalClient(apiKeyProvider: { Keychain.readAPIKey() })
    }

    // MARK: - API key management

    /// Stores the VirusTotal API key in the login Keychain. Once set, future
    /// `virusTotal(sha256:)` calls will hit the network (subject to caching and
    /// rate limiting). Throws `ProviderError.underlying` on Keychain failure.
    public func setAPIKey(_ key: String) throws {
        try Keychain.setAPIKey(key)
    }

    // MARK: - SigningProviding

    public func signature(forPath path: String) async -> SignatureInfo {
        // SHA-256 is computed regardless of code-signing outcome — it is the key
        // used for VirusTotal lookups and is useful even for unsigned binaries.
        let sha = Self.sha256Hex(path: path)

        let url = URL(fileURLWithPath: path)

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            // Could not even form a static code object → treat as invalid, but
            // still return the hash so reputation checks remain possible.
            return SignatureInfo(status: .invalid, sha256: sha)
        }

        // 1) Validity → SigningStatus.
        let checkFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))
        let checkStatus = SecStaticCodeCheckValidity(code, checkFlags, nil)
        let status: SigningStatus
        switch checkStatus {
        case errSecSuccess:    status = .signed
        case errSecCSUnsigned: status = .unsigned
        default:               status = .invalid
        }

        // 2) Copy signing information (signer identity + requirement data).
        var teamID: String?
        var authority: [String] = []
        var isAdHoc = false
        var hasPlatformIdentifier = false

        let infoFlags = SecCSFlags(
            rawValue: UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation))
        var infoCF: CFDictionary?
        if SecCodeCopySigningInformation(code, infoFlags, &infoCF) == errSecSuccess,
           let cf = infoCF {
            let info = cf as NSDictionary

            teamID = info[kSecCodeInfoTeamIdentifier as String] as? String

            // Authority chain: array of SecCertificate → common names.
            if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                for cert in certs {
                    var cn: CFString?
                    if SecCertificateCopyCommonName(cert, &cn) == errSecSuccess,
                       let name = cn as String? {
                        authority.append(name)
                    }
                }
            }

            // Code-signature flags → ad-hoc bit. `kSecCodeSignatureAdhoc` is a
            // C `#define` (SecCode.h) and isn't imported into Swift, so we use
            // its documented value (0x2) directly.
            if let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value {
                let adhocBit: UInt32 = 0x0000_0002
                isAdHoc = (flags & adhocBit) != 0
            }

            // Presence of a platform identifier is the strongest available
            // signal that the OS treats this as a platform binary.
            hasPlatformIdentifier = info[kSecCodeInfoPlatformIdentifier as String] != nil
        }

        let isPlatform = hasPlatformIdentifier || Self.isSystemPath(path)

        // 3) Notarization (approximated — see note below).
        let isNotarized = Self.approximateNotarized(
            status: status, authority: authority, isPlatform: isPlatform, isAdHoc: isAdHoc)

        return SignatureInfo(
            status: status,
            teamID: teamID,
            authority: authority,
            isNotarized: isNotarized,
            isPlatformBinary: isPlatform,
            isAdHoc: isAdHoc,
            sha256: sha,
            virusTotal: nil)
    }

    public func virusTotal(sha256: String) async throws -> VirusTotalResult? {
        try await virusTotalClient.result(forSHA256: sha256)
    }

    // MARK: - Helpers

    /// Streams the file in 1 MiB chunks so large binaries don't get fully
    /// resident in memory. Returns a lowercase hex digest, or `nil` on error.
    static func sha256Hex(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        do {
            while true {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Path-prefix heuristic for OS-shipped binaries.
    static func isSystemPath(_ path: String) -> Bool {
        let prefixes = ["/System/", "/usr/", "/bin/", "/sbin/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// Best-effort notarization signal.
    ///
    /// NOTE (approximation): We deliberately do **not** call the Gatekeeper
    /// assessment API (`SecAssessmentCreate` / `SecAssessmentCopyResult`). That
    /// API performs a full, potentially slow, network-touching security
    /// assessment and its `Unmanaged<CFError>` bridging is awkward and
    /// entitlement-sensitive. Instead we approximate:
    ///
    ///     isNotarized = signed && has a "Developer ID Application" authority
    ///                          && not a platform binary && not ad-hoc
    ///
    /// This correctly flags the common case (a Developer-ID-signed third-party
    /// app, which in practice must be notarized to run) while treating Apple
    /// platform binaries — which are not "notarized" in the Developer ID sense —
    /// as `false`. It can theoretically report a false positive for a
    /// Developer-ID-signed but *un*-notarized binary; a precise check would
    /// require the SecAssessment API noted above.
    static func approximateNotarized(status: SigningStatus,
                                     authority: [String],
                                     isPlatform: Bool,
                                     isAdHoc: Bool) -> Bool {
        guard status == .signed, !isPlatform, !isAdHoc else { return false }
        return authority.contains { $0.contains("Developer ID Application") }
    }
}
