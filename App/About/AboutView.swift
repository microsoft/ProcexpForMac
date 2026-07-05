//
//  AboutView.swift
//  W13 — the application "About" panel.
//
//  Shows the app name, version (read from the bundle's
//  `CFBundleShortVersionString` / `CFBundleVersion`), a short description, and
//  credits mirroring the Sysinternals original. Presented as its own
//  `Window` scene (see `ProcexpApp.swift`) and opened from the app menu's
//  "About Process Explorer" item.
//

import SwiftUI

/// Shared identifier for the About `Window` scene.
enum AboutWindow {
    static let id = "about"
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 128, height: 128))
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Process Explorer")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Version \(shortVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            VStack(spacing: 3) {
                Link("Sysinternals - www.sysinternals.com",
                     destination: URL(string: "https://www.sysinternals.com")!)
                Text("Copyright © 1996–2026 Mark Russinovich")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize()
    }
}

#Preview {
    AboutView()
}
