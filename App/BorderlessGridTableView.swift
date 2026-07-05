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
            return NSColor(srgbRed: 120 / 255, green: 210 / 255, blue: 120 / 255, alpha: 1)
        case .deleted:
            return NSColor(srgbRed: 226 / 255, green: 96 / 255, blue: 96 / 255, alpha: 1)
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
    private let instantTooltip = InstantTableTooltip()
    private var hoverTrackingArea: NSTrackingArea?

    override func keyDown(with event: NSEvent) {
        if let text = event.typeSelectText, typeSelectHandler?(text) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateInstantTooltip(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateInstantTooltip(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        instantTooltip.hide()
    }

    override func mouseDown(with event: NSEvent) {
        instantTooltip.hide()
        super.mouseDown(with: event)
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

    private func updateInstantTooltip(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let text = clippedCellText(at: point), !text.isEmpty else {
            instantTooltip.hide()
            return
        }
        instantTooltip.show(text: text, near: event, from: self)
    }

    private func clippedCellText(at point: NSPoint) -> String? {
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0,
              let cell = view(atColumn: column, row: row, makeIfNecessary: false),
              let textField = firstTextField(in: cell) else { return nil }
        let text = textField.stringValue
        guard !text.isEmpty else { return nil }
        let font = textField.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return width > textField.bounds.width + 0.5 ? text : nil
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}

final class ResizingCursorTableHeaderView: NSTableHeaderView {
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView else { return }
        var x: CGFloat = 0
        for column in tableView.tableColumns.dropLast() {
            x += column.width + tableView.intercellSpacing.width
            addCursorRect(NSRect(x: x - 3, y: bounds.minY, width: 6, height: bounds.height), cursor: .resizeLeftRight)
        }
    }
}

@MainActor
private final class InstantTableTooltip {
    private let maxWidth: CGFloat = 720
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 7
    private let label = NSTextField(labelWithString: "")
    private let container = NSView(frame: .zero)
    private var window: NSWindow?
    private weak var sourceView: NSView?
    private var visibilityTimer: Timer?

    init() {
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        container.addSubview(label)
    }

    func show(text: String, near event: NSEvent, from view: NSView) {
        guard let sourceWindow = view.window else { return }
        sourceView = view
        startVisibilityTimer()
        let size = tooltipSize(for: text)
        label.stringValue = text
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: size.width - horizontalPadding * 2,
            height: size.height - verticalPadding * 2
        )
        container.frame = NSRect(origin: .zero, size: size)

        let tooltipWindow = window ?? makeWindow(size: size)
        window = tooltipWindow
        tooltipWindow.setContentSize(size)
        let screenPoint = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        tooltipWindow.setFrameOrigin(clampedOrigin(near: screenPoint, size: size, screen: sourceWindow.screen ?? NSScreen.main))
        tooltipWindow.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        sourceView = nil
    }

    private func startVisibilityTimer() {
        guard visibilityTimer == nil else { return }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfMouseLeftSource()
            }
        }
    }

    private func hideIfMouseLeftSource() {
        guard let sourceView, let sourceWindow = sourceView.window, sourceWindow.isVisible else {
            hide()
            return
        }
        let windowPoint = sourceWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = sourceView.convert(windowPoint, from: nil)
        if !sourceView.bounds.contains(localPoint) {
            hide()
        }
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let tooltipWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        tooltipWindow.contentView = container
        tooltipWindow.backgroundColor = .clear
        tooltipWindow.isOpaque = false
        tooltipWindow.hasShadow = true
        tooltipWindow.ignoresMouseEvents = true
        tooltipWindow.level = .floating
        return tooltipWindow
    }

    private func tooltipSize(for text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let screenWidth = (sourceView?.window?.screen ?? NSScreen.main)?.visibleFrame.width ?? maxWidth
        let maxContentWidth = min(maxWidth, max(160, screenWidth - 28)) - horizontalPadding * 2
        let naturalWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
        let wrappingWidth = min(maxContentWidth, max(1, naturalWidth))
        let measured = measuredTextRect(for: text, font: font, contentWidth: wrappingWidth)
        let contentWidth = min(wrappingWidth, max(1, ceil(measured.width) + 8))
        let bounds = measuredTextRect(for: text, font: font, contentWidth: contentWidth)
        return NSSize(
            width: contentWidth + horizontalPadding * 2,
            height: ceil(bounds.height) + verticalPadding * 2
        )
    }

    private func measuredTextRect(for text: String, font: NSFont, contentWidth: CGFloat) -> NSRect {
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let layout = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.lineFragmentPadding = 0
        layout.addTextContainer(textContainer)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: textContainer)
        let glyphRange = layout.glyphRange(for: textContainer)
        var maxLineWidth: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            maxLineWidth = max(maxLineWidth, usedRect.maxX)
        }
        let usedRect = layout.usedRect(for: textContainer)
        return NSRect(x: usedRect.minX, y: usedRect.minY, width: max(maxLineWidth, usedRect.width), height: usedRect.height)
    }

    private func clampedOrigin(near point: NSPoint, size: NSSize, screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 6
        var x = point.x + 14
        var y = point.y - size.height - 16
        if y < visible.minY + margin {
            y = point.y + 16
        }
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }
}

extension NSEvent {
    var typeSelectText: String? {
        guard modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let text = charactersIgnoringModifiers,
              !text.isEmpty,
              text != " ",
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return nil }
        return text
    }
}

final class HighlightTableRowView: NSTableRowView {
    var highlight: ListRowHighlightKind?

    override var isSelected: Bool {
        didSet { updateDescendantTextColors() }
    }

    override var isEmphasized: Bool {
        didSet { updateDescendantTextColors() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateDescendantTextColors()
    }

    override func layout() {
        super.layout()
        updateDescendantTextColors()
    }

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

    private func updateDescendantTextColors() {
        setTextColor(isSelected ? .white : .labelColor, in: self)
    }

    private func setTextColor(_ color: NSColor, in view: NSView) {
        if let textField = view as? NSTextField {
            textField.textColor = color
        }
        for subview in view.subviews {
            setTextColor(color, in: subview)
        }
    }
}