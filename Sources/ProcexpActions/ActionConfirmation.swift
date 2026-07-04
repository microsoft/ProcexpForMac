//
//  ActionConfirmation.swift
//  ProcexpActions — W8 (process action command layer)
//
//  Pure-data description of whether a given process action warrants a user
//  confirmation prompt. The UI layer (W3) consumes this to decide when to put
//  up a dialog — this module never touches UI itself.
//

import Foundation

/// The set of control actions the command layer can perform on a process.
public enum ProcessActionKind: String, Sendable, Hashable, CaseIterable, Codable {
    case kill
    case killTree
    case suspend
    case resume
    case setNice
    case restart
    case bringToFront
}

/// Metadata telling the UI whether an action should be confirmed before it runs
/// and how to phrase that confirmation. Pure value type — contains no UI.
public struct ActionConfirmation: Sendable, Hashable, Codable {
    public let kind: ProcessActionKind
    /// Whether the UI should present a confirmation prompt before performing it.
    public let requiresConfirmation: Bool
    /// Whether the action is destructive (irreversible loss of the process).
    public let destructive: Bool
    /// Suggested dialog title.
    public let title: String
    /// Suggested dialog body.
    public let message: String

    public init(
        kind: ProcessActionKind,
        requiresConfirmation: Bool,
        destructive: Bool,
        title: String,
        message: String
    ) {
        self.kind = kind
        self.requiresConfirmation = requiresConfirmation
        self.destructive = destructive
        self.title = title
        self.message = message
    }

    /// Build the confirmation metadata for a given action, optionally including a
    /// human-readable process name so the message can be specific.
    public static func forKind(
        _ kind: ProcessActionKind,
        processName: String? = nil
    ) -> ActionConfirmation {
        let target = processName.map { "“\($0)”" } ?? "this process"
        switch kind {
        case .kill:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: true,
                destructive: true,
                title: "Kill Process?",
                message: "Are you sure you want to kill \(target)? Unsaved data may be lost."
            )
        case .killTree:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: true,
                destructive: true,
                title: "Kill Process Tree?",
                message: "Are you sure you want to kill \(target) and all of its descendant processes? Unsaved data may be lost."
            )
        case .restart:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: true,
                destructive: true,
                title: "Restart Process?",
                message: "Restarting \(target) will terminate it and launch it again. Unsaved data may be lost, and command-line arguments may not be preserved."
            )
        case .suspend:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: false,
                destructive: false,
                title: "Suspend Process",
                message: "Suspend \(target)."
            )
        case .resume:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: false,
                destructive: false,
                title: "Resume Process",
                message: "Resume \(target)."
            )
        case .setNice:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: false,
                destructive: false,
                title: "Change Priority",
                message: "Change the scheduling priority of \(target)."
            )
        case .bringToFront:
            return ActionConfirmation(
                kind: kind,
                requiresConfirmation: false,
                destructive: false,
                title: "Bring to Front",
                message: "Bring \(target) to the front."
            )
        }
    }
}
