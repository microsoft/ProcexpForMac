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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Columns")
                .font(.headline)

            ColumnSelectionEditor(columns: $draftColumns)
                .frame(minHeight: 360)

            HStack {
                Button("Restore Defaults") {
                    draftColumns = Column.defaultColumns
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.columns = AppModel.normalizedColumns(draftColumns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 500)
        .onAppear {
            draftColumns = AppModel.normalizedColumns(model.columns)
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
