//
//  AppDelegate.swift
//  W10 — hosts the menu-bar CPU-history status item alongside the SwiftUI
//  scenes. Attached via `@NSApplicationDelegateAdaptor` in `ProcexpApp`.
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the live CPU-history `NSStatusItem`. Wired to the shared model by
    /// the main scene once it exists (see `ProcexpApp`).
    let menuBar = MenuBarController()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = ProcexpApp.sharedModel
        attach(model: model)
        showMainWindow()
        Task { await model.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Called from the SwiftUI scene's `.task` to hand the delegate the shared
    /// `AppModel`, which it then observes to drive the menu-bar graph.
    func attach(model: AppModel) {
        menuBar.attach(model: model)
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = ContentView()
            .environment(ProcexpApp.sharedModel)
            .frame(minWidth: 900, minHeight: 500)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sysinternals Process Explorer"
        window.titleVisibility = .visible
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }
}
