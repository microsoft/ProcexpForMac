//
//  AutostartProvider.swift
//  ProcexpAutostart — W12
//
//  Resolves the "Autostart Location" for a process, mirroring the equivalent
//  Sysinternals Process Explorer column. The primary mechanism is a scan of the
//  launchd job-definition plists (LaunchDaemons/LaunchAgents); a best-effort
//  heuristic additionally flags app-bundle login items.
//
//  Limitations (documented):
//  - Login Items: macOS provides no public API to enumerate the login items of
//    arbitrary third-party apps. `SMAppService` can register/read state only for
//    the *current* app's own helpers, not for others. We therefore fall back to
//    a heuristic: an executable that lives inside an app bundle under
//    `/Applications` or `~/Applications` and is NOT otherwise explained by a
//    launchd plist is reported as a generic "Login Item". This may produce false
//    positives/negatives and is intentionally conservative.
//  - The launchd scan is read-only and silently ignores missing directories and
//    permission-denied errors, so results depend on what the current user can
//    read (e.g. some `/Library/LaunchDaemons` entries may be inaccessible).
//

import Foundation
import ProcexpModel

/// Resolves autostart sources for processes by consulting a cached index of
/// launchd job definitions, with a best-effort login-item heuristic.
public final class AutostartProvider: AutostartProviding {

    /// Generic label returned when only the login-item heuristic matches.
    public static let loginItemLabel = "Login Item"

    private let index = LaunchdIndex()

    public init() {}

    /// Rebuilds the underlying launchd index from disk. The index is otherwise
    /// built lazily on the first query.
    public func refresh() async {
        await index.refresh()
    }

    public func autostartLocation(for process: ProcessRecord) async -> String? {
        guard let execPath = process.executablePath, !execPath.isEmpty else {
            return nil
        }

        // Primary: a launchd job that launches this executable.
        if let plistPath = await index.plistPath(forExecutablePath: execPath) {
            return plistPath
        }

        // Best-effort fallback: an app-bundle executable in a user-visible
        // Applications directory may be a modern Login Item. See file header.
        if Self.looksLikeLoginItemCandidate(execPath) {
            return Self.loginItemLabel
        }

        return nil
    }

    /// Heuristic: true when `execPath` is inside an `.app` bundle located under
    /// `/Applications` or `~/Applications`. Not authoritative — see header.
    static func looksLikeLoginItemCandidate(_ execPath: String) -> Bool {
        let canonical = LaunchdIndex.canonicalize(execPath)

        guard canonical.contains(".app/") else { return false }

        let userApps = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Applications")
        let roots = ["/Applications", userApps]
        return roots.contains { root in
            canonical == root || canonical.hasPrefix(root + "/")
        }
    }
}
