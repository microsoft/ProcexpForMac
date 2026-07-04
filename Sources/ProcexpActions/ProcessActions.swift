//
//  ProcessActions.swift
//  ProcexpActions — W8 (process action command layer)
//
//  A thin, testable command layer over POSIX signals and AppKit launch/activate
//  APIs. It operates on the *current user's own* processes directly via
//  `Darwin.kill` / `setpriority`, and exposes a privilege-escalation seam so
//  that actions on another user's process — which fail locally with EPERM —
//  can be retried through the W2 privileged root helper.
//
//  Escalation design
//  -----------------
//  Each escalatable action (`kill` / `suspend` / `resume` / `setNice`) first
//  attempts the operation with local POSIX calls. If that fails with
//  `ProviderError.notPermitted`, and an injected `privileged` helper is
//  present, the equivalent privileged method is `await`-ed. If no helper was
//  injected, the original `.notPermitted` is rethrown so the caller can decide
//  whether to install/prompt for the helper. This module never installs or
//  talks to the helper transport itself — it only consumes the
//  `PrivilegedSampling` protocol from `ProcexpModel` (W0).
//
//  CPU affinity is intentionally NOT implemented: macOS exposes no public,
//  supported per-process CPU-affinity API (the old `thread_policy_set`
//  affinity tags are advisory-only and unavailable on Apple Silicon), so there
//  is deliberately no `setAffinity` counterpart to the Windows feature.
//

import Foundation
import Darwin
import AppKit
import ProcexpModel

/// Command layer for controlling processes (kill / suspend / resume / nice /
/// restart / bring-to-front). Value type; safe to pass across actors.
public struct ProcessActions: Sendable {
    /// Optional privileged helper used to retry actions that fail locally with
    /// `.notPermitted` (e.g. another user's process). When `nil`, such failures
    /// are surfaced to the caller unchanged.
    public let privileged: (any PrivilegedSampling)?

    public init(privileged: (any PrivilegedSampling)? = nil) {
        self.privileged = privileged
    }

    // MARK: - Signals

    /// Force-terminate a process (`SIGKILL`).
    ///
    /// Maps `EPERM`/`EACCES` → `.notPermitted` and `ESRCH` → `.processGone`.
    /// On `.notPermitted`, escalates through the privileged helper if injected.
    public func kill(_ id: ProcessID) async throws {
        try await signal(id, SIGKILL)
    }

    /// Suspend a process (`SIGSTOP`).
    public func suspend(_ id: ProcessID) async throws {
        try await signal(id, SIGSTOP)
    }

    /// Resume a suspended process (`SIGCONT`).
    public func resume(_ id: ProcessID) async throws {
        try await signal(id, SIGCONT)
    }

    /// Recursively kill a process and all of its descendants, children first
    /// then the parent (a "kill tree").
    ///
    /// Best-effort: processes that have already exited (`ESRCH` /
    /// `.processGone`) are ignored. Other failures are tolerated so the rest of
    /// the tree is still attempted; the *first* `.notPermitted` encountered is
    /// rethrown at the end so the caller can decide whether to escalate.
    public func killTree(_ id: ProcessID, in snapshot: ProcessSnapshot) async throws {
        var firstNotPermitted: Error?

        // Post-order traversal: descendants before the node itself.
        func recurse(_ node: ProcessID) async {
            for child in snapshot.childIDs(of: node) {
                await recurse(child)
            }
            do {
                try await kill(node)
            } catch ProviderError.processGone {
                // Already gone — nothing to do.
            } catch ProviderError.notPermitted {
                if firstNotPermitted == nil {
                    firstNotPermitted = ProviderError.notPermitted
                }
            } catch {
                // Best-effort: keep tearing down the rest of the tree.
            }
        }

        await recurse(id)
        if let firstNotPermitted { throw firstNotPermitted }
    }

    // MARK: - Scheduling

    /// Set a process's `nice` value via `setpriority(PRIO_PROCESS, …)`.
    ///
    /// `setpriority` legitimately returns `-1` for a valid new priority, so the
    /// result is disambiguated by clearing and re-reading `errno`. On
    /// `.notPermitted`, escalates through the privileged helper if injected.
    public func setNice(_ id: ProcessID, to nice: Int32) async throws {
        errno = 0
        let rc = setpriority(PRIO_PROCESS, id_t(id.pid), nice)
        if rc == -1 && errno != 0 {
            let mapped = Self.mapErrno(errno)
            if case .notPermitted = mapped {
                guard let privileged else { throw ProviderError.notPermitted }
                try await privileged.setNice(id, to: nice)
                return
            }
            throw mapped
        }
    }

    // MARK: - Restart

    /// Terminate a process and launch it again.
    ///
    /// If the process is an `.app` bundle (resolved from its executable path or
    /// bundle identifier) it is relaunched via `NSWorkspace.openApplication`,
    /// which restores the normal app-launch environment. For a plain CLI
    /// executable with no bundle, the binary at `executablePath` is best-effort
    /// re-spawned via `Foundation.Process`.
    ///
    /// - Note: For CLI relaunches the original command-line arguments,
    ///   environment, and working directory are **not** preserved — faithfully
    ///   restoring those requires the privileged helper (W2), which can read
    ///   another process's argv/env. This path launches the bare executable.
    public func restart(_ record: ProcessRecord, in snapshot: ProcessSnapshot) async throws {
        let bundleURL = Self.appBundleURL(for: record)
        let execPath = record.executablePath

        // Capture launch info before we tear the process down.
        try await kill(record.id)

        if let bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        } else if let execPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            do {
                try process.run()
            } catch {
                throw ProviderError.underlying("relaunch failed: \(error.localizedDescription)")
            }
        } else {
            // Nothing to relaunch from.
            throw ProviderError.unsupported
        }
    }

    // MARK: - Activation

    /// Bring a GUI process's windows to the front, if it owns an app.
    ///
    /// No-op when the pid has no associated `NSRunningApplication` (e.g. a
    /// daemon or CLI tool with no GUI). Runs on the main actor because AppKit
    /// activation must occur there.
    @MainActor
    public func bringToFront(_ id: ProcessID) {
        NSRunningApplication(processIdentifier: id.pid)?
            .activate(options: [.activateAllWindows])
    }

    // MARK: - Internals

    /// Send `sig` to `id` locally, escalating to the privileged helper on EPERM.
    private func signal(_ id: ProcessID, _ sig: Int32) async throws {
        do {
            try Self.posixKill(id.pid, sig)
        } catch ProviderError.notPermitted {
            guard let privileged else { throw ProviderError.notPermitted }
            try await privileged.kill(id, signal: sig)
        }
    }

    /// Raw `Darwin.kill` with errno mapping.
    private static func posixKill(_ pid: Int32, _ sig: Int32) throws {
        if Darwin.kill(pid, sig) != 0 {
            throw mapErrno(errno)
        }
    }

    /// Map a POSIX `errno` to a `ProviderError`.
    private static func mapErrno(_ err: Int32) -> ProviderError {
        switch err {
        case EPERM, EACCES:
            return .notPermitted
        case ESRCH:
            return .processGone
        default:
            return .underlying(String(cString: strerror(err)))
        }
    }

    /// Resolve the `.app` bundle URL for a process, if it is a bundled app.
    ///
    /// Prefers walking up the executable path to the enclosing `*.app`; falls
    /// back to resolving the bundle identifier via `NSWorkspace`.
    private static func appBundleURL(for record: ProcessRecord) -> URL? {
        if record.imageType == .appBundle, let path = record.executablePath {
            var url = URL(fileURLWithPath: path)
            while url.pathExtension != "app" && url.path != "/" {
                url = url.deletingLastPathComponent()
            }
            if url.pathExtension == "app" {
                return url
            }
        }
        if let bundleID = record.bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }
}
