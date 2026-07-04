//
//  LaunchdIndex.swift
//  ProcexpAutostart — W12
//
//  A cached, actor-isolated index of launchd job definitions. It scans the
//  well-known LaunchDaemons/LaunchAgents directories once (lazily) and maps the
//  executable each job launches back to the plist that defines it. This is the
//  primary mechanism behind Process Explorer's "Autostart Location" column.
//

import Foundation

/// An entry describing one launchd job definition plist.
struct LaunchdJob: Sendable {
    /// Absolute path to the `.plist` that defines the job.
    let plistPath: String
    /// The job's `Label`, if present.
    let label: String?
    /// The resolved executable path the job launches (`Program` or first
    /// element of `ProgramArguments`), if determinable.
    let programPath: String?
}

/// Actor that owns the launchd job index. Building is lazy and refreshable so
/// callers pay the filesystem cost only once, yet can force a rebuild.
actor LaunchdIndex {

    /// Directories searched for launchd job definitions, in scan order.
    /// `~/Library/LaunchAgents` is expanded for the current user.
    private static var searchDirectories: [String] {
        var dirs = [
            "/System/Library/LaunchDaemons",
            "/System/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
        ]
        // Expand ~/Library/LaunchAgents for the current user.
        let home = NSHomeDirectory()
        dirs.append((home as NSString).appendingPathComponent("Library/LaunchAgents"))
        return dirs
    }

    /// Exact-path index: resolved executable path -> plist path.
    private var byExecutablePath: [String: String] = [:]
    /// Basename fallback index: executable basename -> plist path.
    private var byBasename: [String: String] = [:]
    /// Whether the index has been built at least once.
    private var isBuilt = false

    /// Ensures the index exists, building it on first use.
    private func ensureBuilt() {
        guard !isBuilt else { return }
        rebuild()
    }

    /// Forces a full rebuild of the index from disk.
    func refresh() {
        rebuild()
    }

    /// Looks up the autostart plist path for a resolved executable path.
    /// Prefers an exact path match, falling back to basename matching.
    func plistPath(forExecutablePath executablePath: String) -> String? {
        ensureBuilt()

        let resolved = LaunchdIndex.canonicalize(executablePath)
        if let hit = byExecutablePath[resolved] {
            return hit
        }
        let base = (resolved as NSString).lastPathComponent
        return byBasename[base]
    }

    // MARK: - Building

    private func rebuild() {
        byExecutablePath.removeAll(keepingCapacity: true)
        byBasename.removeAll(keepingCapacity: true)

        let fm = FileManager.default
        for directory in LaunchdIndex.searchDirectories {
            // Read-only enumeration; missing dirs / permission errors are ignored.
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for entry in entries where entry.hasSuffix(".plist") {
                let plistPath = (directory as NSString).appendingPathComponent(entry)
                guard let job = LaunchdIndex.parseJob(atPath: plistPath) else {
                    continue
                }
                guard let program = job.programPath else { continue }
                let canonical = LaunchdIndex.canonicalize(program)

                // First writer wins (system dirs scanned before user dirs), so a
                // more authoritative definition is not clobbered by a later one.
                if byExecutablePath[canonical] == nil {
                    byExecutablePath[canonical] = plistPath
                }
                let base = (canonical as NSString).lastPathComponent
                if byBasename[base] == nil {
                    byBasename[base] = plistPath
                }
            }
        }
        isBuilt = true
    }

    /// Parses a single launchd job plist, extracting label and program path.
    /// Returns nil if the file cannot be read or parsed as a dictionary.
    static func parseJob(atPath path: String) -> LaunchdJob? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        let label = dict["Label"] as? String

        var program: String?
        if let explicit = dict["Program"] as? String, !explicit.isEmpty {
            program = explicit
        } else if let args = dict["ProgramArguments"] as? [Any],
            let first = args.first as? String, !first.isEmpty
        {
            program = first
        }

        return LaunchdJob(plistPath: path, label: label, programPath: program)
    }

    /// Normalizes a path for comparison by standardizing `.`/`..` and symlink
    /// resolution where possible, falling back to a lexical standardization.
    static func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        // `standardizingPath` resolves symlinks for existing paths and cleans
        // up the rest lexically, which is sufficient for index keys.
        return standardized
    }
}
