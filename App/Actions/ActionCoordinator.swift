//
//  ActionCoordinator.swift
//  W8 — Bridges the main-window UI (context menu + toolbar) to the
//  `ProcexpActions.ProcessActions` command layer.
//
//  Responsibilities:
//  - Look up the `ProcessRecord` for a `ProcessID` in the current snapshot.
//  - Decide (via `ActionConfirmation.forKind`) whether an action needs a
//    confirmation prompt; if so, stage it in `pending` for the view to show a
//    `.confirmationDialog`. Otherwise perform it immediately.
//  - Run the matching async `ProcessActions` method on the main actor and turn
//    thrown `ProviderError`s into user-facing alert text:
//      * `.notPermitted`  → "elevated privileges required" (the W2 helper will
//        enable cross-user actions later).
//      * `.processGone`   → silently ignored (it already exited; the next
//        refresh drops the row).
//      * anything else    → a generic "action failed" alert.
//
//  The type is `@Observable`, so mutating `pending` / `errorMessage` drives the
//  SwiftUI dialogs that observe it. It never mutates the process list itself —
//  a killed process simply disappears on the next snapshot.
//

import Foundation
import Observation
import ProcexpModel
import ProcexpActions

@MainActor
@Observable
final class ActionCoordinator {
    /// A confirmation-requiring action staged for the view to present.
    struct Pending: Identifiable {
        let id = UUID()
        let kind: ProcessActionKind
        let pid: ProcessID
        let confirmation: ActionConfirmation

        /// Verb for the confirm button ("Kill", "Kill Tree", "Restart").
        var confirmButtonTitle: String {
            switch kind {
            case .kill: return "Kill"
            case .killTree: return "Kill Tree"
            case .restart: return "Restart"
            case .suspend: return "Suspend"
            case .resume: return "Resume"
            case .setNice: return "Change Priority"
            case .bringToFront: return "Bring to Front"
            }
        }
    }

    /// Non-nil while a confirmation dialog should be shown.
    var pending: Pending?

    /// Non-nil while an error alert should be shown.
    var errorTitle: String = ""
    var errorMessage: String?

    // MARK: - Entry points

    /// Request an action for a process. Presents a confirmation prompt when the
    /// action's `ActionConfirmation` demands one; otherwise performs it now.
    func request(_ kind: ProcessActionKind, pid: ProcessID, model: AppModel) {
        guard let record = model.snapshot.info(pid) else { return }
        let confirmation = ActionConfirmation.forKind(kind, processName: record.name)
        if confirmation.requiresConfirmation && model.confirmBeforeKill {
            pending = Pending(kind: kind, pid: pid, confirmation: confirmation)
        } else {
            Task { await perform(kind, pid: pid, model: model) }
        }
    }

    /// The user confirmed the staged action — run it.
    func confirm(model: AppModel) {
        guard let staged = pending else { return }
        pending = nil
        Task { await perform(staged.kind, pid: staged.pid, model: model) }
    }

    /// The user dismissed the confirmation prompt.
    func cancel() {
        pending = nil
    }

    /// Change a process's scheduling priority (nice). Never needs confirmation.
    func setPriority(pid: ProcessID, nice: Int32, model: AppModel) {
        Task { await perform(.setNice, pid: pid, model: model, nice: nice) }
    }

    // MARK: - Execution

    private func perform(
        _ kind: ProcessActionKind,
        pid: ProcessID,
        model: AppModel,
        nice: Int32 = 0
    ) async {
        guard let record = model.snapshot.info(pid) else { return }
        let actions = model.actions
        do {
            switch kind {
            case .kill:
                try await actions.kill(pid)
            case .killTree:
                try await actions.killTree(pid, in: model.snapshot)
            case .suspend:
                try await actions.suspend(pid)
            case .resume:
                try await actions.resume(pid)
            case .setNice:
                try await actions.setNice(pid, to: nice)
            case .restart:
                try await actions.restart(record, in: model.snapshot)
            case .bringToFront:
                actions.bringToFront(pid)
            }
        } catch ProviderError.notPermitted {
            errorTitle = "Elevated Privileges Required"
            errorMessage = "“\(record.name)” (PID \(record.id.pid)) belongs to another user or is protected, so this action requires elevated privileges. A privileged helper — coming in a later update — will enable actions across users."
        } catch ProviderError.processGone {
            // The process already exited; nothing to report. The next refresh
            // removes its row.
        } catch ProviderError.unsupported {
            errorTitle = "Action Not Supported"
            errorMessage = "This action isn’t available for “\(record.name)” (PID \(record.id.pid))."
        } catch let ProviderError.underlying(detail) {
            errorTitle = "Action Failed"
            errorMessage = detail
        } catch {
            errorTitle = "Action Failed"
            errorMessage = error.localizedDescription
        }
    }
}
