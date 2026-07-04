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
    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 128, height: 128))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Process Explorer")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Version \(shortVersion) (build \(buildVersion))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("A native macOS process viewer that shows a live tree of "
                     + "running processes, per-process CPU/memory/GPU/network "
                     + "activity, loaded modules, open handles, code-signing "
                     + "status, and system-wide performance graphs.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                Divider()
                    .padding(.vertical, 2)

                Text("A macOS port inspired by Sysinternals Process Explorer "
                     + "by Mark Russinovich.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Sysinternals Process Explorer",
                     destination: URL(string: "https://learn.microsoft.com/sysinternals/downloads/process-explorer")!)
                    .font(.footnote)

                Text("© Process Explorer for macOS")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(width: 460, height: 260)
    }
}

#Preview {
    AboutView()
}
