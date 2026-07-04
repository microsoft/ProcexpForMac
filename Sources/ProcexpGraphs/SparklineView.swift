//
//  SparklineView.swift
//  ProcexpGraphs — W4
//
//  A compact filled line graph suitable for embedding in a table cell.
//  Draws a single `[Double]` history scaled to `0...maxValue`, oldest → newest
//  (left → right). Redraws whenever any public property changes.
//

import AppKit
import ProcexpModel

@MainActor
public final class SparklineView: NSView {

    /// Sample history, oldest → newest. Redraws on set.
    public var values: [Double] = [] {
        didSet { needsDisplay = true }
    }

    /// Upper bound used to scale samples. Values above are clamped.
    public var maxValue: Double = 100 {
        didSet { needsDisplay = true }
    }

    /// Stroke color of the line.
    public var lineColor: RGBA = RGBA(0, 200, 0) {
        didSet { needsDisplay = true }
    }

    /// Fill color under the line.
    public var fillColor: RGBA = RGBA(0, 200, 0, 0.25) {
        didSet { needsDisplay = true }
    }

    /// Background fill.
    public var graphBackgroundColor: RGBA = RGBA(0, 0, 0) {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public override var isFlipped: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        // Background.
        NSColor(graphBackgroundColor).setFill()
        bounds.fill()

        guard values.count > 1, bounds.width > 0, bounds.height > 0 else { return }

        let denom = maxValue > 0 ? maxValue : 1
        let stepX = bounds.width / CGFloat(values.count - 1)

        func point(at index: Int) -> NSPoint {
            let clamped = min(max(values[index], 0), denom)
            let y = bounds.minY + CGFloat(clamped / denom) * bounds.height
            let x = bounds.minX + CGFloat(index) * stepX
            return NSPoint(x: x, y: y)
        }

        // Filled area under the line.
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        for index in values.indices {
            fill.line(to: point(at: index))
        }
        fill.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        fill.close()
        NSColor(fillColor).setFill()
        fill.fill()

        // Line stroke.
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: point(at: 0))
        for index in values.indices.dropFirst() {
            line.line(to: point(at: index))
        }
        NSColor(lineColor).setStroke()
        line.stroke()
    }
}
