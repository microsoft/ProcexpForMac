//
//  HistoryGraphView.swift
//  ProcexpGraphs — W4
//
//  A larger scrolling history graph mirroring Process Explorer's System
//  Information CPU/memory graphs: grid lines, newest sample on the right, and
//  support for a second overlaid series (e.g. kernel time over total CPU).
//
//  Each series is drawn oldest → newest (left → right). Series are expected to
//  share the same `maxValue` scale.
//

import AppKit
import ProcexpModel

@MainActor
public final class HistoryGraphView: NSView {

    /// One or two data series, oldest → newest. Redraws on set.
    public var series: [[Double]] = [] {
        didSet { needsDisplay = true }
    }

    /// Stroke/fill color per series (index-matched to `series`).
    public var seriesColors: [RGBA] = [RGBA(0, 200, 0), RGBA(200, 0, 0)] {
        didSet { needsDisplay = true }
    }

    /// Upper bound used to scale all series. Values above are clamped.
    public var maxValue: Double = 100 {
        didSet { needsDisplay = true }
    }

    /// Grid line color.
    public var gridColor: RGBA = RGBA(0, 80, 0) {
        didSet { needsDisplay = true }
    }

    /// Background fill.
    public var graphBackgroundColor: RGBA = RGBA(0, 0, 0) {
        didSet { needsDisplay = true }
    }

    /// Toggle the grid overlay.
    public var showGrid: Bool = true {
        didSet { needsDisplay = true }
    }

    /// Number of horizontal/vertical grid divisions.
    public var gridDivisions: Int = 4 {
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
        guard bounds.width > 0, bounds.height > 0 else { return }

        NSColor(graphBackgroundColor).setFill()
        bounds.fill()

        if showGrid {
            drawGrid(in: bounds)
        }

        let denom = maxValue > 0 ? maxValue : 1
        for (index, samples) in series.enumerated() {
            let color = seriesColors.indices.contains(index)
                ? seriesColors[index]
                : RGBA(0, 200, 0)
            draw(samples: samples, color: color, denom: denom, in: bounds)
        }
    }

    private func drawGrid(in bounds: NSRect) {
        guard gridDivisions > 0 else { return }
        NSColor(gridColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5

        // Horizontal lines.
        for step in 0...gridDivisions {
            let y = bounds.minY + bounds.height * CGFloat(step) / CGFloat(gridDivisions)
            path.move(to: NSPoint(x: bounds.minX, y: y))
            path.line(to: NSPoint(x: bounds.maxX, y: y))
        }
        // Vertical lines.
        for step in 0...gridDivisions {
            let x = bounds.minX + bounds.width * CGFloat(step) / CGFloat(gridDivisions)
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
        }
        path.stroke()
    }

    private func draw(samples: [Double], color: RGBA, denom: Double, in bounds: NSRect) {
        guard samples.count > 1 else { return }
        let stepX = bounds.width / CGFloat(samples.count - 1)

        func point(at index: Int) -> NSPoint {
            let clamped = min(max(samples[index], 0), denom)
            let y = bounds.minY + CGFloat(clamped / denom) * bounds.height
            let x = bounds.minX + CGFloat(index) * stepX
            return NSPoint(x: x, y: y)
        }

        // Faint fill under the line for the primary look.
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        for index in samples.indices {
            fill.line(to: point(at: index))
        }
        fill.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        fill.close()
        NSColor(RGBA(r: color.r, g: color.g, b: color.b, a: 0.20)).setFill()
        fill.fill()

        // Line stroke.
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: point(at: 0))
        for index in samples.indices.dropFirst() {
            line.line(to: point(at: index))
        }
        NSColor(color).setStroke()
        line.stroke()
    }
}
