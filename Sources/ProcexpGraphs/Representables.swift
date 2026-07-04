//
//  Representables.swift
//  ProcexpGraphs — W4
//
//  Thin SwiftUI wrappers so W3/W6 can embed the AppKit graph views directly in
//  SwiftUI hierarchies (System Information window, table cells, etc.).
//

import SwiftUI
import ProcexpModel

/// SwiftUI wrapper around `SparklineView`.
public struct SparklineRepresentable: NSViewRepresentable {
    public var values: [Double]
    public var maxValue: Double
    public var lineColor: RGBA
    public var fillColor: RGBA
    public var backgroundColor: RGBA

    public init(
        values: [Double],
        maxValue: Double = 100,
        lineColor: RGBA = RGBA(0, 200, 0),
        fillColor: RGBA = RGBA(0, 200, 0, 0.25),
        backgroundColor: RGBA = RGBA(0, 0, 0)
    ) {
        self.values = values
        self.maxValue = maxValue
        self.lineColor = lineColor
        self.fillColor = fillColor
        self.backgroundColor = backgroundColor
    }

    public func makeNSView(context: Context) -> SparklineView {
        let view = SparklineView()
        apply(to: view)
        return view
    }

    public func updateNSView(_ nsView: SparklineView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: SparklineView) {
        view.maxValue = maxValue
        view.lineColor = lineColor
        view.fillColor = fillColor
        view.graphBackgroundColor = backgroundColor
        view.values = values
    }
}

/// SwiftUI wrapper around `HistoryGraphView`.
public struct HistoryGraphRepresentable: NSViewRepresentable {
    public var series: [[Double]]
    public var seriesColors: [RGBA]
    public var maxValue: Double
    public var gridColor: RGBA
    public var backgroundColor: RGBA
    public var showGrid: Bool

    public init(
        series: [[Double]],
        seriesColors: [RGBA] = [RGBA(0, 200, 0), RGBA(200, 0, 0)],
        maxValue: Double = 100,
        gridColor: RGBA = RGBA(0, 80, 0),
        backgroundColor: RGBA = RGBA(0, 0, 0),
        showGrid: Bool = true
    ) {
        self.series = series
        self.seriesColors = seriesColors
        self.maxValue = maxValue
        self.gridColor = gridColor
        self.backgroundColor = backgroundColor
        self.showGrid = showGrid
    }

    public func makeNSView(context: Context) -> HistoryGraphView {
        let view = HistoryGraphView()
        apply(to: view)
        return view
    }

    public func updateNSView(_ nsView: HistoryGraphView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: HistoryGraphView) {
        view.maxValue = maxValue
        view.seriesColors = seriesColors
        view.gridColor = gridColor
        view.graphBackgroundColor = backgroundColor
        view.showGrid = showGrid
        view.series = series
    }
}
