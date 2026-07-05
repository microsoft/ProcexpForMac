//
//  ProcexpApp.swift
//  Process Explorer for macOS — app entry point.
//

import SwiftUI
import AppKit
import ProcexpModel

@main
struct ProcexpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    static let sharedModel = AppModel()
    @State private var model = ProcexpApp.sharedModel

    var body: some Scene {
        WindowGroup("Sysinternals Process Explorer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 650)
        .commands {
            // R1 — the full Process Explorer menu bar (File / Options / View /
            // Process / Find). Without this the custom menus never appear.
            AppMenuCommands(model: model)

            // W13 — present the custom About panel instead of the default
            // AppKit about box.
            CommandGroup(replacing: .appInfo) {
                AboutMenuCommand()
            }
            // W2 — install the privileged root helper (mirrors Procexp's
            // "Run as Administrator"). Reports success/failure via an alert,
            // and disables itself once the helper is installed.
            CommandGroup(after: .appSettings) {
                InstallHelperMenuCommand(model: model)
            }
            // W4 — open the System Information window (⌘I).
            CommandGroup(after: .toolbar) {
                SystemInfoMenuCommand()
            }

            // Remove the default macOS "Help" menu.
            CommandGroup(replacing: .help) { }
        }

        // W6 — one Process Properties window per process. Opening the same
        // `ProcessID` again just refocuses its existing window.
        WindowGroup(id: PropertiesWindow.id, for: ProcessID.self) { $pid in
            if let pid {
                ProcessPropertiesView(pid: pid)
                    .environment(model)
            }
        }
        .defaultSize(width: 760, height: 620)

        // R3 — DLL / mapped-image detail window (double-click a row in the
        // lower pane's DLLs list). Multiple may be open at once, keyed by
        // process + image path.
        WindowGroup(id: ModuleDetailWindow.id, for: ModuleDetailID.self) { $moduleID in
            if let moduleID {
                ModuleDetailView(id: moduleID)
                    .environment(model)
            }
        }
        .defaultSize(width: 520, height: 480)

        // R3 — Handle / object detail window (double-click a row in the lower
        // pane's Handles list). Keyed by process + file descriptor.
        WindowGroup(id: HandleDetailWindow.id, for: HandleDetailID.self) { $handleID in
            if let handleID {
                HandleDetailView(id: handleID)
            }
        }
        .defaultSize(width: 460, height: 300)

        // W4 — single shared System Information window (multi-graph). Opening
        // it again just refocuses the existing window.
        Window("System Information", id: SystemInfoWindow.id) {
            SystemInfoView()
                .environment(model)
        }
        .defaultSize(width: 620, height: 560)

        // Process Explorer Find ▸ Find Handle or DLL… window. This is a real
        // window (not a sheet) so it has standard close/minimize/zoom controls.
        Window("Find Handle or DLL", id: FindHandleDLLWindow.id) {
            FindHandleDLLView()
                .environment(model)
        }
        .defaultSize(width: 860, height: 520)

        // W11 — native Preferences window (standard ⌘, shortcut + "Settings…"
        // menu item). Binds directly into the shared `AppModel`.
        Settings {
            SettingsView()
                .environment(model)
        }

        // W13 — the About panel, opened from the app's About menu
        // menu item. A single shared window; re-opening just refocuses it.
        Window("About Sysinternals Process Explorer", id: AboutWindow.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Menu command that opens the custom About panel (replaces the default
/// AppKit about box via `CommandGroup(replacing: .appInfo)`).
private struct AboutMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Sysinternals Process Explorer") {
            openWindow(id: AboutWindow.id)
        }
    }
}

/// Menu command that opens the shared System Information window (⌘I).
private struct SystemInfoMenuCommand: View {    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("System Information") {
            openWindow(id: SystemInfoWindow.id)
        }
        .keyboardShortcut("i", modifiers: .command)
    }
}

/// Menu command to install the privileged root helper. Disabled (greyed out)
/// once the helper is installed, since there is nothing more to do. A companion
/// "Uninstall…" item (enabled only when installed) unregisters it — no sudo, so
/// it is handy for re-testing the first-install flow.
private struct InstallHelperMenuCommand: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(model.helperInstalled ? "Privileged Helper Installed" : "Install Privileged Helper…") {
            let model = model
            Task { await runHelperInstall(model) }
        }
        .disabled(model.helperInstalled)

        Button("Uninstall Privileged Helper…") {
            let model = model
            Task { await runHelperUninstall(model) }
        }
        .disabled(!model.helperInstalled)
    }
}


/// Shared identifier for the Process Properties `WindowGroup`.
enum PropertiesWindow {
    static let id = "process-properties"
}

enum FindHandleDLLWindow {
    static let id = "find-handle-dll"
}

/// W2 — run the privileged-helper install flow and report the outcome in a
/// modal alert. Kept as a free `@MainActor` function so the menu command can
/// simply capture the shared `AppModel`.
@MainActor
private func runHelperInstall(_ model: AppModel) async {
    let result = await model.installPrivilegedHelper()
    let alert = NSAlert()
    alert.messageText = result.ok ? "Privileged Helper Installed" : "Could Not Install Helper"
    alert.informativeText = result.message
    alert.alertStyle = result.ok ? .informational : .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

/// W2 — unregister the privileged helper and report the outcome.
@MainActor
private func runHelperUninstall(_ model: AppModel) async {
    let result = await model.uninstallPrivilegedHelper()
    let alert = NSAlert()
    alert.messageText = result.ok ? "Privileged Helper Removed" : "Could Not Remove Helper"
    alert.informativeText = result.message
    alert.alertStyle = result.ok ? .informational : .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
