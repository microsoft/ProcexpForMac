//
//  ColumnManagementViews.swift
//  Column selection and named column-set management for the process list.
//

import SwiftUI
import ProcexpModel

struct SelectColumnsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draftColumns: [Column] = Column.defaultColumns
    @State private var draftModuleColumns: [ModuleColumn] = ModuleColumn.defaultColumns
    @State private var draftHandleColumns: [HandleColumn] = HandleColumn.defaultColumns
    @State private var draftThreadColumns: [ThreadColumn] = ThreadColumn.defaultColumns
    @State private var selectedTab: ColumnSelectionTab = .process

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Columns")
                .font(.headline)

            Picker("", selection: $selectedTab) {
                ForEach(ColumnSelectionTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            selectedEditor
                .frame(minHeight: 360)

            HStack {
                Button("Restore Defaults") {
                    restoreDefaultsForSelectedTab()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.columns = AppModel.normalizedColumns(draftColumns)
                    model.moduleColumns = AppModel.normalizedModuleColumns(draftModuleColumns)
                    model.handleColumns = AppModel.normalizedHandleColumns(draftHandleColumns)
                    model.threadColumns = AppModel.normalizedThreadColumns(draftThreadColumns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .onAppear {
            draftColumns = AppModel.normalizedColumns(model.columns)
            draftModuleColumns = AppModel.normalizedModuleColumns(model.moduleColumns)
            draftHandleColumns = AppModel.normalizedHandleColumns(model.handleColumns)
            draftThreadColumns = AppModel.normalizedThreadColumns(model.threadColumns)
        }
    }

    @ViewBuilder private var selectedEditor: some View {
        switch selectedTab {
        case .process:
            ColumnSelectionEditor(columns: $draftColumns)
        case .dlls:
            LowerPaneColumnSelectionEditor(columns: $draftModuleColumns)
        case .handles:
            LowerPaneColumnSelectionEditor(columns: $draftHandleColumns)
        case .threads:
            LowerPaneColumnSelectionEditor(columns: $draftThreadColumns)
        }
    }

    private func restoreDefaultsForSelectedTab() {
        switch selectedTab {
        case .process: draftColumns = Column.defaultColumns
        case .dlls: draftModuleColumns = ModuleColumn.defaultColumns
        case .handles: draftHandleColumns = HandleColumn.defaultColumns
        case .threads: draftThreadColumns = ThreadColumn.defaultColumns
        }
    }
}

private enum ColumnSelectionTab: String, CaseIterable, Identifiable {
    case process
    case dlls
    case handles
    case threads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .process: return "Process"
        case .dlls: return "DLLs"
        case .handles: return "Handles"
        case .threads: return "Threads"
        }
    }
}

struct SaveColumnSetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var replacesExisting: Bool {
        model.hasColumnSet(named: trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Column Set")
                .font(.headline)

            TextField("Name", text: $name)
                .focused($nameFocused)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(replacesExisting ? "Replace" : "Save") {
                    if model.saveCurrentColumnSet(named: name) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            if name.isEmpty { name = model.defaultColumnSetName() }
            nameFocused = true
        }
    }

    private var summary: String {
        let columns = AppModel.normalizedColumns(model.columns)
        let metricCount = max(0, columns.count - 1)
        return "Process column plus \(metricCount) metric column\(metricCount == 1 ? "" : "s")."
    }
}

struct OrganizeColumnSetsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedName: String?
    @State private var deleteCandidate: ColumnSet?

    private var selectedSet: ColumnSet? {
        guard let selectedName else { return nil }
        return model.columnSets.first { $0.name == selectedName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organize Column Sets")
                .font(.headline)

            if model.columnSets.isEmpty {
                VStack(spacing: 6) {
                    Text("No saved column sets")
                        .font(.headline)
                    Text("Save the current layout from the View menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(selection: $selectedName) {
                    ForEach(model.columnSets) { set in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(set.name)
                                .foregroundStyle(selectedName == set.name ? Color.white : Color.primary)
                            Text(summary(for: set))
                                .font(.caption)
                                .foregroundStyle(selectedName == set.name ? Color.white : Color.secondary)
                                .lineLimit(1)
                        }
                        .tag(set.name)
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button("Load") {
                    if let selectedSet {
                        model.applyColumnSet(selectedSet)
                        dismiss()
                    }
                }
                .disabled(selectedSet == nil)

                Button("Delete", role: .destructive) {
                    deleteCandidate = selectedSet
                }
                .disabled(selectedSet == nil)

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.columnSets) { selectFirstIfNeeded() }
        .alert("Delete Column Set?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), presenting: deleteCandidate) { set in
            Button("Delete", role: .destructive) {
                model.deleteColumnSet(set)
                deleteCandidate = nil
                selectFirstIfNeeded()
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { set in
            Text("Delete \"\(set.name)\"?")
        }
    }

    private func selectFirstIfNeeded() {
        guard !model.columnSets.isEmpty else {
            selectedName = nil
            return
        }
        if selectedSet == nil {
            selectedName = model.columnSets.first?.name
        }
    }

    private func summary(for set: ColumnSet) -> String {
        let columns = AppModel.normalizedColumns(set.columns)
        let preview = columns.prefix(4).map(\.title).joined(separator: ", ")
        let remaining = max(0, columns.count - 4)
        return remaining == 0 ? preview : "\(preview) +\(remaining)"
    }
}

struct ColumnSelectionEditor: View {
    @Binding var columns: [Column]
    @State private var selectedRows = Set<String>()

    private var normalizedColumns: [Column] {
        AppModel.normalizedColumns(columns)
    }

    var body: some View {
        List(selection: $selectedRows) {
            ForEach(Column.supportedOnMac, id: \.self) { column in
                Toggle(isOn: binding(for: column)) {
                    Text(column.title)
                        .foregroundStyle(selectedRows.contains(rowID(for: column)) ? Color.white : Color.primary)
                }
                .toggleStyle(.checkbox)
                .disabled(column == .name || column == .pid)
                .tag(rowID(for: column))
            }
        }
    }

    private func rowID(for column: Column) -> String {
        column.rawValue
    }

    private func binding(for column: Column) -> Binding<Bool> {
        Binding(
            get: { AppModel.normalizedColumns(columns).contains(column) },
            set: { isOn in
                if isOn {
                    guard !AppModel.normalizedColumns(columns).contains(column) else { return }
                    columns = AppModel.normalizedColumns(columns + [column])
                } else {
                    guard column != .name && column != .pid else { return }
                    columns = AppModel.normalizedColumns(columns.filter { $0 != column })
                }
            }
        )
    }
}

struct LowerPaneColumnSelectionEditor<C: LowerPaneColumn>: View {
    @Binding var columns: [C]
    @State private var selectedRows = Set<String>()

    private var normalizedColumns: [C] {
        normalized(columns)
    }

    var body: some View {
        List(selection: $selectedRows) {
            ForEach(Array(C.allCases), id: \.self) { column in
                Toggle(isOn: binding(for: column)) {
                    Text(column.title)
                        .foregroundStyle(selectedRows.contains(column.rawValue) ? Color.white : Color.primary)
                }
                .toggleStyle(.checkbox)
                .disabled(C.requiredColumns.contains(column))
                .tag(column.rawValue)
            }
        }
    }

    private func binding(for column: C) -> Binding<Bool> {
        Binding(
            get: { normalizedColumns.contains(column) },
            set: { isOn in
                var current = normalizedColumns
                if isOn {
                    guard !current.contains(column) else { return }
                    current.append(column)
                } else {
                    guard !C.requiredColumns.contains(column) else { return }
                    current.removeAll { $0 == column }
                }
                columns = normalized(current)
            }
        )
    }

    private func normalized(_ columns: [C]) -> [C] {
        var seen = Set<C>()
        var result: [C] = []
        for column in C.requiredColumns where seen.insert(column).inserted {
            result.append(column)
        }
        for column in columns where seen.insert(column).inserted {
            result.append(column)
        }
        return result.isEmpty ? C.requiredColumns : result
    }
}
