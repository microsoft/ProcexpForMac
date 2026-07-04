//
//  AppMenus.swift
//  R1 — Native menu bar mirroring the Windows Process Explorer menu tree
//  (see docs/UX_OVERHAUL_PLAN.md). Real commands are wired to `AppModel` /
//  `ActionCoordinator`; features without a backing implementation yet are
//  enabled no-op stubs, marked `// STUB`.
//

import SwiftUI
import AppKit
import ProcexpModel
import ProcexpActions

/// The full set of custom menus, inserted from `ProcexpApp.commands`.
struct AppMenuCommands: Commands {
    let model: AppModel

    /// Windows "Del" is the forward-delete key; using `.deleteForward` avoids
    /// hijacking Backspace while editing the search field.
    private static let killKey = KeyEquivalent.deleteForward
    /// F5 — the Refresh Now accelerator.
    private static let f5 = KeyEquivalent(Character(UnicodeScalar(0xF708)!))

    var body: some Commands {
        // FILE — Run / Save / Save As / Shutdown.
        CommandGroup(replacing: .newItem) {
            Button("Run…") { model.showRunSheet = true }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Save") { model.saveRequestToken += 1 }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { model.saveRequestToken += 1 }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Menu("Shutdown") {
                Button("Log Off…") { NSWorkspaceStub.beep() }        // STUB
                Button("Restart…") { NSWorkspaceStub.beep() }        // STUB
                Button("Shut Down…") { NSWorkspaceStub.beep() }      // STUB
            }
        }

        // OPTIONS.
        CommandMenu("Options") {
            OptionsMenu(model: model)
        }

        // VIEW.
        CommandMenu("View") {
            ViewMenu(model: model, f5: Self.f5)
        }

        // PROCESS.
        CommandMenu("Process") {
            ProcessMenu(model: model, killKey: Self.killKey)
        }

        // FIND.
        CommandMenu("Find") {
            FindMenu(model: model)
        }
    }
}

private struct FindMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Find Handle or DLL…") { openWindow(id: FindHandleDLLWindow.id) }
            .keyboardShortcut("f", modifiers: .command)
        Button("Filter Processes…") { model.focusSearchToken += 1 }
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

// MARK: - Options

private struct OptionsMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle("Verify Image Signatures", isOn: $model.verifySignatures)
        Toggle("Confirm Kill", isOn: $model.confirmBeforeKill)
        Toggle("Always On Top", isOn: $model.alwaysOnTop)

        Divider()

        Picker("Theme", selection: $model.theme) {
            ForEach(AppTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }

        Divider()

        // STUBS — no backing implementation yet.
        Button("Run At Logon") { NSWorkspaceStub.beep() }
        Button("Hide When Minimized") { NSWorkspaceStub.beep() }
        Button("Allow Only One Instance") { NSWorkspaceStub.beep() }
        Button("Highlight Relocated DLLs") { NSWorkspaceStub.beep() }
    }
}

// MARK: - View

private struct ViewMenu: View {
    @Bindable var model: AppModel
    let f5: KeyEquivalent

    private let speeds: [TimeInterval] = [0.5, 1, 2, 5, 10]

    var body: some View {
        Toggle("Show Process Tree", isOn: $model.showProcessTree)
            .keyboardShortcut("t", modifiers: .command)
        Toggle("Show Lower Pane", isOn: $model.showLowerPane)
            .keyboardShortcut("l", modifiers: .command)

        Menu("Lower Pane View") {
            Button("DLLs") {
                model.lowerPaneMode = .modules
                model.showLowerPane = true
            }
            .keyboardShortcut("d", modifiers: .command)
            Button("Handles") {
                model.lowerPaneMode = .handles
                model.showLowerPane = true
            }
            .keyboardShortcut("h", modifiers: .command)
            Button("Threads") {
                model.lowerPaneMode = .threads
                model.showLowerPane = true
            }
            .keyboardShortcut("y", modifiers: .command)
        }

        Divider()

        Button("Refresh Now") { Task { await model.forceRefresh() } }
            .keyboardShortcut(f5, modifiers: [])

        Menu("Update Speed") {
            ForEach(speeds, id: \.self) { speed in
                Toggle(speedLabel(speed), isOn: Binding(
                    get: { !model.paused && model.refreshInterval == speed },
                    set: { _ in
                        model.paused = false
                        model.refreshInterval = speed
                        Task { await model.start() }
                    }
                ))
            }
            Divider()
            Toggle("Paused", isOn: Binding(
                get: { model.paused },
                set: { _ in model.togglePause() }
            ))
        }

        Divider()

        Button("Select Columns…") { model.showSelectColumnsSheet = true }
        Menu("Load Column Set") {
            if model.columnSets.isEmpty {
                Button("No Saved Column Sets") { }
                    .disabled(true)
            } else {
                ForEach(model.columnSets) { set in
                    Button(set.name) { model.applyColumnSet(set) }
                }
            }
        }
        Button("Save Column Set…") { model.showSaveColumnSetSheet = true }
        Button("Organize Column Sets…") { model.showOrganizeColumnSetsSheet = true }

        Divider()

        // STUBS.
        Button("Show Processes From All Users") { NSWorkspaceStub.beep() }
    }

    private func speedLabel(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.1f sec", seconds) : "\(Int(seconds)) sec"
    }
}

// MARK: - Process

private struct ProcessMenu: View {
    @Bindable var model: AppModel
    let killKey: KeyEquivalent
    @Environment(\.openWindow) private var openWindow

    private let priorities: [(String, Int32)] = [
        ("Idle (19)", 19),
        ("Below Normal (10)", 10),
        ("Normal (0)", 0),
        ("Above Normal (-10)", -10),
        ("High (-20)", -20),
    ]

    var body: some View {
        Button("Kill Process") { request(.kill) }
            .keyboardShortcut(killKey, modifiers: [])
            .disabled(model.selection == nil)
        Button("Kill Process Tree") { request(.killTree) }
            .keyboardShortcut(killKey, modifiers: .shift)
            .disabled(model.selection == nil)

        Button(suspendTitle) { toggleSuspend() }
            .disabled(model.selection == nil)
        Button("Restart") { request(.restart) }
            .disabled(model.selection == nil)

        Menu("Set Priority") {
            ForEach(priorities, id: \.0) { title, nice in
                Button(title) {
                    if let pid = model.selection {
                        model.actionCoordinator.setPriority(pid: pid, nice: nice, model: model)
                    }
                }
            }
        }
        .disabled(model.selection == nil)

        Button("Bring to Front") { request(.bringToFront) }
            .disabled(model.selection == nil)
        Button("Sample Process…") { model.sampleSelectedProcess() }
            .disabled(model.selection == nil)

        Divider()

        Button("Search Online") { model.searchOnlineForSelectedProcess() }
            .disabled(model.selection == nil)
        Button("Check VirusTotal") {
            Task { await model.checkVirusTotalForSelectedProcess() }
        }
        .disabled(model.selection == nil)

        Divider()

        Button("Properties…") {
            if let pid = model.selection {
                openWindow(id: PropertiesWindow.id, value: pid)
            }
        }
        .disabled(model.selection == nil)
    }

    private var suspendTitle: String {
        let suspended = model.selection
            .flatMap { model.snapshot.info($0)?.flags.contains(.suspended) } ?? false
        return suspended ? "Resume" : "Suspend"
    }

    private func request(_ kind: ProcessActionKind) {
        guard let pid = model.selection else { return }
        model.actionCoordinator.request(kind, pid: pid, model: model)
    }

    private func toggleSuspend() {
        guard let pid = model.selection else { return }
        let suspended = model.snapshot.info(pid)?.flags.contains(.suspended) ?? false
        model.actionCoordinator.request(suspended ? .resume : .suspend, pid: pid, model: model)
    }
}

/// A no-op signal for enabled-but-unimplemented menu stubs.
private enum NSWorkspaceStub {
    static func beep() { NSSound.beep() }
}
