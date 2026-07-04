//
//  SettingsStore.swift
//  W11 — Persists user preferences to `UserDefaults` and restores them into
//  `AppModel` at launch. Kept deliberately simple and robust: scalars are
//  stored natively, `columns` as an array of `Column.rawValue` strings, and
//  `colorRules` as JSON (Codable round-trip). Any decode failure falls back to
//  the model's existing (default) value, so a corrupt/absent key never crashes.
//

import Foundation
import ProcexpModel

/// Namespaced UserDefaults-backed persistence for the W11 settings surface.
@MainActor
enum SettingsStore {

    /// Storage keys (namespaced to avoid clashing with other defaults).
    private enum Key {
        static let schema             = "settings.schemaVersion"
        static let refreshInterval    = "settings.refreshInterval"
        static let columns            = "settings.columns"
        static let processColumnWidth = "settings.processColumnWidth"
        static let columnWidths       = "settings.columnWidths"
        static let colorRules         = "settings.colorRules"
        static let useMockData        = "settings.useMockData"
        static let confirmBeforeKill  = "settings.confirmBeforeKill"
        static let verifySignatures   = "settings.verifySignatures"
        static let highlightDuration  = "settings.differenceHighlightDuration"
    }

    private static let schemaVersion = 1

    // MARK: - Load

    /// Restore any persisted settings into `model`. Missing keys leave the
    /// model's current defaults untouched.
    static func load(into model: AppModel, defaults: UserDefaults = .standard) {
        // Only trust keys once the schema marker is present (first launch has none).
        guard defaults.integer(forKey: Key.schema) == schemaVersion else { return }

        if let interval = defaults.object(forKey: Key.refreshInterval) as? Double,
           interval > 0 {
            model.refreshInterval = interval
        }

        if let raw = defaults.array(forKey: Key.columns) as? [String] {
            let restored = raw.compactMap(Column.init(rawValue:))
            if !restored.isEmpty { model.columns = restored }
        }

        if let width = defaults.object(forKey: Key.processColumnWidth) as? Double, width > 0 {
            model.processColumnWidth = width
        }

        if let widths = defaults.dictionary(forKey: Key.columnWidths) as? [String: Double] {
            model.columnWidths = widths.filter { Column(rawValue: $0.key) != nil && $0.value > 0 }
        }

        if let data = defaults.data(forKey: Key.colorRules),
           let rules = try? JSONDecoder().decode([ProcessColorRule].self, from: data),
           !rules.isEmpty {
            model.colorRules = rules
        }

        if defaults.object(forKey: Key.useMockData) != nil {
            model.useMockData = defaults.bool(forKey: Key.useMockData)
        }
        if defaults.object(forKey: Key.confirmBeforeKill) != nil {
            model.confirmBeforeKill = defaults.bool(forKey: Key.confirmBeforeKill)
        }
        if defaults.object(forKey: Key.verifySignatures) != nil {
            model.verifySignatures = defaults.bool(forKey: Key.verifySignatures)
        }
        if let dur = defaults.object(forKey: Key.highlightDuration) as? Double, dur >= 0 {
            model.differenceHighlightDuration = dur
        }
    }

    // MARK: - Save

    /// Persist the current settings from `model`. Called whenever a persisted
    /// value changes (see `AppModel.persistSettings()`).
    static func save(from model: AppModel, defaults: UserDefaults = .standard) {
        defaults.set(schemaVersion, forKey: Key.schema)
        defaults.set(model.refreshInterval, forKey: Key.refreshInterval)
        defaults.set(model.columns.map(\.rawValue), forKey: Key.columns)
        defaults.set(model.processColumnWidth, forKey: Key.processColumnWidth)
        defaults.set(model.columnWidths, forKey: Key.columnWidths)
        if let data = try? JSONEncoder().encode(model.colorRules) {
            defaults.set(data, forKey: Key.colorRules)
        }
        defaults.set(model.useMockData, forKey: Key.useMockData)
        defaults.set(model.confirmBeforeKill, forKey: Key.confirmBeforeKill)
        defaults.set(model.verifySignatures, forKey: Key.verifySignatures)
        defaults.set(model.differenceHighlightDuration, forKey: Key.highlightDuration)
    }
}
