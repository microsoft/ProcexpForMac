//
//  SettingsView.swift
//  W11 — The native macOS Preferences window (a SwiftUI `Settings` scene, so it
//  gets the standard ⌘, shortcut and "Settings…" menu item). Three tabs:
//  General, Colors, Columns. Every control binds straight into `AppModel`, whose
//  `didSet` observers persist the change via `SettingsStore`.
//

import SwiftUI
import ProcexpModel

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            ColorSettingsView()
                .tabItem { Label("Colors", systemImage: "paintpalette") }

            ColumnSettingsView()
                .tabItem { Label("Columns", systemImage: "tablecells") }
        }
        .environment(model)
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Refresh-rate choices offered in the picker (seconds).
    private static let intervals: [TimeInterval] = [0.5, 1, 2, 5, 10]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Update interval:", selection: $model.refreshInterval) {
                    ForEach(Self.intervals, id: \.self) { value in
                        Text(Self.label(for: value)).tag(value)
                    }
                }
                .onChange(of: model.refreshInterval) {
                    Task { await model.start() }
                }
            }

            Section {
                Toggle("Use mock data (demo tree)", isOn: $model.useMockData)
                    .onChange(of: model.useMockData) {
                        Task { await model.start() }
                    }
                Toggle("Confirm before killing a process", isOn: $model.confirmBeforeKill)
                Toggle("Verify code signatures", isOn: $model.verifySignatures)
            }

            Section {
                Picker("Difference highlight duration:",
                       selection: $model.differenceHighlightDuration) {
                    Text("Off").tag(TimeInterval(0))
                    Text("1 second").tag(TimeInterval(1))
                    Text("2 seconds").tag(TimeInterval(2))
                    Text("3 seconds").tag(TimeInterval(3))
                    Text("5 seconds").tag(TimeInterval(5))
                }
            } footer: {
                Text("How long newly started or exited processes stay highlighted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private static func label(for value: TimeInterval) -> String {
        value < 1
            ? String(format: "%.1f seconds", value)
            : "\(Int(value)) second\(value == 1 ? "" : "s")"
    }
}

// MARK: - Colors

private struct ColorSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Row colors")
                .font(.headline)
            Text("Colors apply to the process tree in order — the first enabled "
                 + "rule that matches a process wins.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($model.colorRules) { $rule in
                    HStack(spacing: 12) {
                        Toggle(isOn: $rule.isEnabled) {
                            Text(Self.name(for: rule.flag))
                        }
                        .toggleStyle(.checkbox)

                        Spacer()

                        ColorPicker("Light", selection: $rule.backgroundLight.asColor,
                                    supportsOpacity: false)
                            .labelsHidden()
                        Text("Light").font(.caption).foregroundStyle(.secondary)

                        ColorPicker("Dark", selection: $rule.backgroundDark.asColor,
                                    supportsOpacity: false)
                            .labelsHidden()
                        Text("Dark").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    model.colorRules = ProcessColorRule.defaults
                }
            }
        }
        .padding()
    }

    /// Human-readable label for a legend flag (there is no `.title` on `ProcessFlags`).
    static func name(for flag: ProcessFlags) -> String {
        switch flag {
        case .ownProcess:  return "Own Processes"
        case .service:     return "Services"
        case .suspended:   return "Suspended"
        case .sandboxed:   return "Sandboxed"
        case .packed:      return "Packed Images"
        case .newProcess:  return "New Processes"
        case .deadProcess: return "Deleted Processes"
        default:           return "Other"
        }
    }
}

// MARK: - Columns

private struct ColumnSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Visible columns")
                .font(.headline)
            Text("Choose which columns appear in the process tree. Drag to reorder "
                 + "the selected columns.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                // Selected columns first, in their current (draggable) order.
                Section("Shown") {
                    ForEach(model.columns, id: \.self) { column in
                        Toggle(isOn: binding(for: column)) { Text(column.title) }
                            .toggleStyle(.checkbox)
                            .disabled(column == .name) // Process name is always shown.
                    }
                    .onMove { indices, newOffset in
                        model.columns.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }

                // The remaining, currently-hidden columns.
                let hidden = Column.allCases.filter { !model.columns.contains($0) }
                if !hidden.isEmpty {
                    Section("Available") {
                        ForEach(hidden, id: \.self) { column in
                            Toggle(isOn: binding(for: column)) { Text(column.title) }
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    model.columns = Column.defaultColumns
                }
            }
        }
        .padding()
    }

    /// A toggle binding that inserts/removes a column from `model.columns`,
    /// keeping `.name` pinned first so the tree always has its outline column.
    private func binding(for column: Column) -> Binding<Bool> {
        Binding(
            get: { model.columns.contains(column) },
            set: { isOn in
                if isOn {
                    guard !model.columns.contains(column) else { return }
                    model.columns.append(column)
                } else {
                    guard column != .name else { return }
                    model.columns.removeAll { $0 == column }
                }
            }
        )
    }
}
