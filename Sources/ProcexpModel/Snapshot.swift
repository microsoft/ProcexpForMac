//
//  Snapshot.swift
//  ProcexpModel — W0 shared contracts
//
//  The immutable "whole world at one instant" that the UI renders from.
//

import Foundation

/// A complete sample of all processes plus system-wide stats at one instant.
public struct ProcessSnapshot: Sendable {
    public let timestamp: Date
    /// Wall-clock seconds since the previous snapshot (used for rate math).
    public let interval: TimeInterval
    public let processes: [ProcessID: ProcessRecord]
    /// Top-level processes (those whose parent is not present / is the root).
    public let roots: [ProcessID]
    /// Parent → children adjacency describing the process tree.
    public let children: [ProcessID: [ProcessID]]
    public let system: SystemStats

    public init(
        timestamp: Date,
        interval: TimeInterval,
        processes: [ProcessID: ProcessRecord],
        roots: [ProcessID],
        children: [ProcessID: [ProcessID]],
        system: SystemStats
    ) {
        self.timestamp = timestamp
        self.interval = interval
        self.processes = processes
        self.roots = roots
        self.children = children
        self.system = system
    }

    public static let empty = ProcessSnapshot(
        timestamp: .distantPast,
        interval: 0,
        processes: [:],
        roots: [],
        children: [:],
        system: .zero
    )

    public func info(_ id: ProcessID) -> ProcessRecord? { processes[id] }
    public func childIDs(of id: ProcessID) -> [ProcessID] { children[id] ?? [] }
}

/// The result of diffing two consecutive snapshots — what the UI needs to
/// animate new/dead rows.
public struct SnapshotDiff: Sendable {
    public let added: Set<ProcessID>
    public let removed: Set<ProcessID>
    public let changed: Set<ProcessID>

    public init(added: Set<ProcessID>, removed: Set<ProcessID>, changed: Set<ProcessID>) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    /// Compute what changed between `old` and `new`.
    public static func between(_ old: ProcessSnapshot, _ new: ProcessSnapshot) -> SnapshotDiff {
        let oldKeys = Set(old.processes.keys)
        let newKeys = Set(new.processes.keys)
        let added = newKeys.subtracting(oldKeys)
        let removed = oldKeys.subtracting(newKeys)
        var changed = Set<ProcessID>()
        for key in newKeys.intersection(oldKeys) where old.processes[key] != new.processes[key] {
            changed.insert(key)
        }
        return SnapshotDiff(added: added, removed: removed, changed: changed)
    }
}

/// Tree-building helper so every provider produces a consistent `roots`/`children`
/// layout from a flat `[ProcessID: ProcessRecord]` map.
public enum ProcessTreeBuilder {
    /// Build `(roots, children)` from a flat process map.
    ///
    /// A process is a root when it has no parent, its parent is itself, or its
    /// parent is not present in `processes`. Children are returned sorted by PID
    /// for stable ordering; callers may re-sort by the active column.
    public static func build(
        from processes: [ProcessID: ProcessRecord]
    ) -> (roots: [ProcessID], children: [ProcessID: [ProcessID]]) {
        var children: [ProcessID: [ProcessID]] = [:]
        var roots: [ProcessID] = []

        for (id, info) in processes {
            if let parent = info.parent, parent != id, processes[parent] != nil {
                children[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }

        for key in children.keys {
            children[key]?.sort { $0.pid < $1.pid }
        }
        roots.sort { $0.pid < $1.pid }
        return (roots, children)
    }
}
