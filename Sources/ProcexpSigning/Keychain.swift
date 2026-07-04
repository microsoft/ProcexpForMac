//
//  Keychain.swift
//  ProcexpSigning — W7
//
//  Minimal generic-password Keychain helper used to store the VirusTotal API
//  key. The key never lives in source or plists; users configure it once via
//  `CodeSignProvider.setAPIKey(_:)` and it is read back on demand.
//

import Foundation
import Security
import ProcexpModel

/// Namespaced Keychain access for the VirusTotal API key.
///
/// Stateless (an empty `enum`), so it is trivially `Sendable`. The underlying
/// `SecItem*` calls are thread-safe, so this can be used from any actor.
enum Keychain {
    /// Generic-password service name, as specified by the W7 contract.
    static let service = "com.sysinternals.procexpmac.virustotal"
    /// Single account under the service — we only ever store one API key.
    static let account = "api-key"

    /// Reads the stored API key, or `nil` if none has been configured.
    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Stores (or replaces) the API key. Throws `ProviderError.underlying` on
    /// any Keychain failure so callers get a descriptive message.
    static func setAPIKey(_ key: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Replace semantics: delete any existing item, then add fresh.
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderError.underlying("Keychain write failed (OSStatus \(status))")
        }
    }
}
