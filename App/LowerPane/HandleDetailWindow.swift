//
//  HandleDetailWindow.swift
//  R3 — Handle / object (file-descriptor) detail window.
//
//  Opened by double-clicking a row in the lower pane's Handles list. Shows the
//  descriptor number, its kind (FDKind) and the resolved name (path, addr:port
//  or description). When the handle refers to a vnode path a "Reveal in Finder"
//  action is offered. Presented as a `WindowGroup(for: HandleDetailID.self)` so
//  several may be open at once.
//

import SwiftUI
import AppKit
import ProcexpModel

/// Scene identifier for the handle/object detail `WindowGroup`.
enum HandleDetailWindow {
    static let id = "handle-detail"
}

/// Codable & Hashable identifier carrying everything needed to render a handle
/// detail window.
struct HandleDetailID: Codable, Hashable {
    var pid: Int32
    var startTime: UInt64
    var fd: Int32
    var kind: String        // FDKind.rawValue
    var name: String
    var processName: String
}

struct HandleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let id: HandleDetailID

    /// True when the handle's name looks like a real filesystem path.
    private var isRevealablePath: Bool {
        id.kind == FDKind.vnode.rawValue
            && id.name.hasPrefix("/")
            && FileManager.default.fileExists(atPath: id.name)
    }

    private var kindTitle: String {
        switch FDKind(rawValue: id.kind) ?? .other {
        case .vnode:    return "File / vnode"
        case .socket:   return "Socket"
        case .pipe:     return "Pipe"
        case .kqueue:   return "Kernel queue"
        case .fsevent:  return "File-system events"
        case .machPort: return "Mach port"
        case .other:    return "Other"
        }
    }

    private var nameLabel: String {
        switch FDKind(rawValue: id.kind) ?? .other {
        case .vnode:  return "Path"
        case .socket: return "Address"
        default:      return "Name"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    detail("File descriptor", String(id.fd))
                    detail("Type", kindTitle)
                    detail(nameLabel, id.name.isEmpty ? "—" : id.name, scroll: true)
                    detail("Owned by", "\(id.processName) (PID \(id.pid))")
                }

                if isRevealablePath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: id.name)]
                        )
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 240)
        .navigationTitle("Handle \(id.fd)")
        .onExitCommand { dismiss() }
        .background(EscapeKeyMonitor { dismiss() })
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: headerIcon)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Handle \(id.fd) — \(kindTitle)")
                    .font(.title3).bold()
                Text(id.name.isEmpty ? "(no name)" : id.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var headerIcon: NSImage {
        if isRevealablePath {
            return NSWorkspace.shared.icon(forFile: id.name)
        }
        let symbol: String
        switch FDKind(rawValue: id.kind) ?? .other {
        case .socket:   symbol = "network"
        case .pipe:     symbol = "arrow.left.arrow.right"
        case .kqueue:   symbol = "tray.full"
        case .fsevent:  symbol = "eye"
        case .machPort: symbol = "bolt.horizontal"
        case .vnode:    symbol = "doc"
        case .other:    symbol = "questionmark.square"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: kindTitle)
            ?? NSImage()
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String, scroll: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            if scroll {
                ScrollingValue(text: value, font: .callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
