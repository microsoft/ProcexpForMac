//
//  TableColumnPersistence.swift
//  Shared AppKit table column order/width persistence.
//

import AppKit

@MainActor
enum TableColumnPersistence {
    static func apply(to tableView: NSTableView, key: String, defaults: UserDefaults = .standard) {
        let widthKey = key + ".widths"
        if let widths = defaults.dictionary(forKey: widthKey) as? [String: Double] {
            for column in tableView.tableColumns {
                if let width = widths[column.identifier.rawValue], width > 0 {
                    column.width = CGFloat(width)
                }
            }
        }

        let orderKey = key + ".order"
        guard let order = defaults.array(forKey: orderKey) as? [String], !order.isEmpty else { return }
        for (targetIndex, id) in order.enumerated() where targetIndex < tableView.tableColumns.count {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
                  currentIndex != targetIndex else { continue }
            tableView.moveColumn(currentIndex, toColumn: targetIndex)
        }
    }

    static func save(from tableView: NSTableView, key: String, defaults: UserDefaults = .standard) {
        defaults.set(tableView.tableColumns.map { $0.identifier.rawValue }, forKey: key + ".order")
        let widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns.map {
            ($0.identifier.rawValue, Double($0.width))
        })
        defaults.set(widths, forKey: key + ".widths")
    }
}
