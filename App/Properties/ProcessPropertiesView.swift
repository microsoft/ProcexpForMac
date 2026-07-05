//
//  ProcessPropertiesView.swift
//  W6 — Process Properties window.
//
//  Top-level tabbed inspector for one process. Opened via a
//  `WindowGroup(id: "process-properties", for: ProcessID.self)` scene, so one
//  window exists per `ProcessID` (opening the same pid again just refocuses the
//  existing window).
//
//  Live update:
//  - `record` is recomputed from `model.snapshot` on every render, so all
//    `ProcessRecord`-derived values (CPU, memory, threads, I/O, …) track the
//    1s main refresh automatically (AppModel is `@Observable`).
//  - Async details (threads, sockets, environment, strings, signature) live in
//    a per-window `PropertiesDetail`. `.task(id: pid)` loads the static pieces
//    once, then refreshes the dynamic lists on a ~1.5s timer while open.
//

import SwiftUI
import AppKit
import ProcexpModel

struct ProcessPropertiesView: View {
    let pid: ProcessID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail = PropertiesDetail()
    @State private var selectedTab: PropertiesTab = .image

    /// The live record for this pid, or `nil` once the process exits.
    private var record: ProcessRecord? { model.snapshot.processes[pid] }

    /// Shared action coordinator (kill / bring-to-front) — same instance the
    /// main window and menu bar use.
    private var coordinator: ActionCoordinator { model.actionCoordinator }

    /// The Windows Procexp tab set, in order.
    enum PropertiesTab: String, CaseIterable, Identifiable {
        case image = "Image"
        case signature = "Signature"
        case performance = "Performance"
        case performanceGraph = "Performance Graph"
        case threads = "Threads"
        case tcpip = "TCP/IP"
        case security = "Security"
        case environment = "Environment"
        case strings = "Strings"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let record {
                VStack(spacing: 0) {
                    // A real top tab strip (Windows Procexp style) instead of the
                    // macOS-26 sidebar/slide-out that `TabView` now defaults to.
                    tabStrip
                    Divider()
                    // Each tab manages its own scrolling (Form/List/Table), so
                    // don't wrap in an outer ScrollView (it breaks Table sizing).
                    tabContent(record: record)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 640, idealWidth: 680, minHeight: 560, idealHeight: 600)
                .navigationTitle("\(record.name) (PID \(pid.pid)) Properties")
            } else {
                ContentUnavailableView(
                    "Process Exited",
                    systemImage: "xmark.octagon",
                    description: Text("PID \(pid.pid) is no longer running.")
                )
                .frame(minWidth: 480, minHeight: 300)
                .navigationTitle("PID \(pid.pid) Properties")
            }
        }
        // Feed the per-process history rings once per snapshot tick.
        .onChange(of: model.snapshot.timestamp) {
            if let record = model.snapshot.processes[pid] {
                detail.appendHistory(record: record, at: model.snapshot.timestamp)
            }
        }
        .task(id: pid) {
            let record = model.snapshot.processes[pid]
            await detail.loadStatic(
                pid: pid,
                record: record,
                data: model.data,
                signing: model.signing,
                autostart: model.autostart
            )
            // Seed the rings with the first sample immediately.
            if let record { detail.appendHistory(record: record, at: model.snapshot.timestamp) }
            while !Task.isCancelled {
                await detail.refreshDynamic(
                    pid: pid,
                    record: model.snapshot.processes[pid],
                    data: model.data,
                    network: model.network,
                    highlightDuration: model.differenceHighlightDuration
                )
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        // Present the shared coordinator's confirmation + error UI so Kill /
        // Bring to Front launched from this window behave like the main window.
        .confirmationDialog(
            coordinator.pending?.confirmation.title ?? "",
            isPresented: Binding(
                get: { coordinator.pending != nil },
                set: { if !$0 { coordinator.cancel() } }
            ),
            presenting: coordinator.pending
        ) { pending in
            Button(
                pending.confirmButtonTitle,
                role: pending.confirmation.destructive ? .destructive : nil
            ) {
                coordinator.confirm(model: model)
            }
            Button("Cancel", role: .cancel) { coordinator.cancel() }
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .alert(
            coordinator.errorTitle,
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .onExitCommand {
            if coordinator.pending != nil {
                coordinator.cancel()
            } else {
                dismiss()
            }
        }
        .background(EscapeKeyMonitor {
            if coordinator.pending != nil {
                coordinator.cancel()
            } else {
                dismiss()
            }
        })
    }

    // MARK: - Custom top tab strip

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(PropertiesTab.allCases) { tab in
                let selected = tab == selectedTab
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? Color.accentColor.opacity(0.20) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear,
                                        lineWidth: 1)
                        )
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tabContent(record: ProcessRecord) -> some View {
        switch selectedTab {
        case .image:            ImageTab(pid: pid, record: record, detail: detail).padding(8)
        case .signature:        SignatureTab(record: record, detail: detail).padding(8)
        case .performance:      PerformanceTab(record: record, detail: detail).padding(8)
        case .performanceGraph: PerformanceGraphTab(detail: detail).padding(8)
        case .threads:          ThreadsTab(record: record, detail: detail).padding(8)
        case .tcpip:            TCPIPTab(detail: detail).padding(8)
        case .security:         SecurityTab(record: record, detail: detail).padding(8)
        case .environment:      EnvironmentTab(detail: detail).padding(8)
        case .strings:          StringsTab(detail: detail).padding(8)
        }
    }
}

struct EscapeKeyMonitor: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.attach(to: view)
    }

    final class Coordinator {
        var action: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.keyCode == 53, event.window === self.view?.window else { return event }
                self.action()
                return nil
            }
        }
    }
}
