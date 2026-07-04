//
//  BorderlessGridTableView.swift
//  NSTableView variant that draws interior vertical separators only.
//

import AppKit

enum ListRowHighlightKind {
    case new
    case deleted

    var color: NSColor {
        switch self {
        case .new:
            return NSColor(srgbRed: 198 / 255, green: 246 / 255, blue: 198 / 255, alpha: 1)
        case .deleted:
            return NSColor(srgbRed: 246 / 255, green: 198 / 255, blue: 198 / 255, alpha: 1)
        }
    }
}

struct TimedListRowHighlight {
    var kind: ListRowHighlightKind
    var expiresAt: Date
}

final class TypeSelectBuffer {
    private var prefix = ""
    private var lastInput = Date.distantPast
    private let timeout: TimeInterval = 1.0

    func append(_ text: String) -> String {
        let now = Date()
        if now.timeIntervalSince(lastInput) > timeout {
            prefix = ""
        }
        lastInput = now
        prefix += text.lowercased()
        return prefix
    }

    func reset(to text: String) -> String {
        lastInput = Date()
        prefix = text.lowercased()
        return prefix
    }
}

final class BorderlessGridTableView: NSTableView {
    var typeSelectHandler: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let text = event.typeSelectText, typeSelectHandler?(text) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func drawGrid(inClipRect clipRect: NSRect) {
        guard !tableColumns.isEmpty else { return }
        NSColor.gridColor.setStroke()
        var x: CGFloat = 0
        for index in 0..<(tableColumns.count - 1) {
            x += tableColumns[index].width + intercellSpacing.width
            NSBezierPath.strokeLine(
                from: NSPoint(x: x, y: clipRect.minY),
                to: NSPoint(x: x, y: clipRect.maxY)
            )
        }
    }
}

extension NSEvent {
    var typeSelectText: String? {
        guard modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let text = charactersIgnoringModifiers,
              !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return nil }
        return text
    }
}

final class HighlightTableRowView: NSTableRowView {
    var highlight: ListRowHighlightKind?

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            super.drawBackground(in: dirtyRect)
            return
        }
        if let highlight {
            highlight.color.setFill()
            dirtyRect.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }
}