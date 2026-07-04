//
//  SystemInfoView.swift
//  W4 — System Information window.
//
//  Mirrors Process Explorer's "System Information" multi-graph window: live
//  scrolling history graphs for CPU (total + per-core), memory (physical +
//  swap), disk I/O, network and GPU. Each graph is fed by a `HistoryRing` on
//  the shared `AppModel`, so everything updates at the refresh cadence.
//

import SwiftUI
import ProcexpModel
import ProcexpGraphs

/// Shared identifier for the System Information `Window` scene.
enum SystemInfoWindow {
    static let id = "system-information"
}

struct SystemInfoView: View {
    @Environment(AppModel.self) private var model

    /// Static hardware description, gathered once and cached.
    private let hardware = HardwareInfo.current

    var body: some View {
        TabView {
            summaryTab
                .tabItem { Label("Summary", systemImage: "chart.bar.doc.horizontal") }
            cpuTab
                .tabItem { Label("CPU", systemImage: "cpu") }
            memoryTab
                .tabItem { Label("Memory", systemImage: "memorychip") }
            ioTab
                .tabItem { Label("I/O", systemImage: "internaldrive") }
            networkTab
                .tabItem { Label("Network", systemImage: "network") }
            gpuTab
                .tabItem { Label("GPU", systemImage: "gpu.card") }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: - Tabs

    private var summaryTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                hardwareSummaryPanel
                cpuTotalPanel
                memoryPanel
                swapPanel
                diskPanel
                networkPanel
                gpuPanel
            }
            .padding(.vertical, 4)
        }
    }

    private var cpuTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                cpuHardwarePanel
                cpuTotalPanel
                if !model.perCoreHistory.isEmpty {
                    Text("Per-Core Usage")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    perCoreGrid
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var memoryTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                memoryHardwarePanel
                memoryPanel
                swapPanel
            }
            .padding(.vertical, 4)
        }
    }

    private var ioTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                storageHardwarePanel
                diskPanel
            }
            .padding(.vertical, 4)
        }
    }

    private var networkTab: some View {
        VStack { networkPanel; Spacer(minLength: 0) }
    }

    private var gpuTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                gpuHardwarePanel
                gpuPanel
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Hardware panels

    /// Top-of-Summary overview: machine, OS, CPU, memory, GPU(s), boot volume.
    private var hardwareSummaryPanel: some View {
        InfoGroup(title: "System") {
            InfoRow("Machine", hardware.machineModel)
            InfoRow("macOS", hardware.osVersion)
            InfoRow("Host", hardware.hostName)
            InfoRow("Architecture", hardware.architecture)
            InfoRow("CPU", hardware.cpuBrand)
            InfoRow("Cores", "\(hardware.coreSummary) • \(hardware.logicalCores) logical")
            InfoRow("Memory", ByteFormat.bytes(hardware.physicalMemory))
            if let gpu = hardware.gpus.first {
                InfoRow("GPU", gpuLabel(gpu))
            }
            if let volume = hardware.bootVolume {
                InfoRow("Boot Volume", volumeLabel(volume))
            }
        }
    }

    /// CPU tab detail: model, core topology, packages, frequency.
    private var cpuHardwarePanel: some View {
        InfoGroup(title: "Processor") {
            InfoRow("Model", hardware.cpuBrand)
            InfoRow("Cores", hardware.coreSummary)
            InfoRow("Topology", hardware.cpuTopologyDetail)
            if let p = hardware.performanceCores, let e = hardware.efficiencyCores {
                InfoRow("Performance", "\(p) cores")
                InfoRow("Efficiency", "\(e) cores")
            }
            InfoRow("Packages", "\(hardware.packages)")
            if let freq = hardware.cpuFrequencyHz {
                InfoRow("Base Frequency", String(format: "%.2f GHz", Double(freq) / 1_000_000_000))
            }
            InfoRow("Architecture", hardware.architecture)
        }
    }

    /// Memory tab detail: installed RAM, page size.
    private var memoryHardwarePanel: some View {
        InfoGroup(title: "Physical Memory") {
            InfoRow("Installed", ByteFormat.bytes(hardware.physicalMemory))
            InfoRow("Page Size", ByteFormat.bytes(hardware.pageSize))
            if let gpu = hardware.gpus.first, gpu.unifiedMemory {
                InfoRow("Type", "Unified Memory")
            }
        }
    }

    /// GPU tab detail: enumerate every Metal device.
    private var gpuHardwarePanel: some View {
        InfoGroup(title: hardware.gpus.count == 1 ? "Graphics Device" : "Graphics Devices") {
            if hardware.gpus.isEmpty {
                InfoRow("GPU", "None detected")
            } else {
                ForEach(hardware.gpus) { gpu in
                    InfoRow(gpu.name, gpuDetail(gpu))
                }
            }
        }
    }

    /// I/O tab detail: boot volume name, capacity, type.
    private var storageHardwarePanel: some View {
        InfoGroup(title: "Storage") {
            if let volume = hardware.bootVolume {
                InfoRow("Boot Volume", volume.name)
                InfoRow("Type", volume.mediaType)
                InfoRow("Capacity", ByteFormat.bytes(volume.totalCapacity))
                InfoRow("Available", ByteFormat.bytes(volume.availableCapacity))
                InfoRow("Used", ByteFormat.bytes(volume.totalCapacity - volume.availableCapacity))
            } else {
                InfoRow("Boot Volume", "Unavailable")
            }
        }
    }

    // MARK: Hardware formatting helpers

    private func gpuLabel(_ gpu: HardwareInfo.GPUInfo) -> String {
        if let vram = gpu.vram {
            return "\(gpu.name) (\(ByteFormat.bytes(vram)))"
        }
        return gpu.name
    }

    private func gpuDetail(_ gpu: HardwareInfo.GPUInfo) -> String {
        var parts: [String] = []
        if let vram = gpu.vram { parts.append(ByteFormat.bytes(vram)) }
        parts.append(gpu.unifiedMemory ? "Unified" : "Discrete")
        if gpu.lowPower { parts.append("Low-Power") }
        if gpu.removable { parts.append("Removable") }
        if gpu.headless { parts.append("Headless") }
        return parts.joined(separator: " • ")
    }

    private func volumeLabel(_ volume: HardwareInfo.VolumeInfo) -> String {
        let free = ByteFormat.bytes(volume.availableCapacity)
        let total = ByteFormat.bytes(volume.totalCapacity)
        return "\(volume.name) — \(free) free of \(total) (\(volume.mediaType))"
    }


    // MARK: - Panels

    private var cpuTotalPanel: some View {
        GraphPanel(
            title: "CPU Usage (Total)",
            values: model.cpuHistory.values,
            color: RGBA(0, 200, 0),
            unit: .percent,
            topConsumers: model.cpuTopHistory.values,
            consumerUnit: .percent,
            secondsPerSample: model.refreshInterval
        )
    }

    private var memoryPanel: some View {
        GraphPanel(
            title: "Physical Memory",
            values: model.memoryHistory.values,
            color: RGBA(230, 90, 90),
            unit: .percent,
            topConsumers: model.memoryTopHistory.values,
            consumerUnit: .bytes,
            secondsPerSample: model.refreshInterval
        )
    }

    private var swapPanel: some View {
        GraphPanel(
            title: "Swap Used",
            values: model.swapHistory.values,
            color: RGBA(255, 180, 0),
            unit: .bytes,
            secondsPerSample: model.refreshInterval
        )
    }

    private var diskPanel: some View {
        GraphPanel(
            title: "Disk I/O",
            values: model.diskHistory.values,
            color: RGBA(0, 160, 255),
            unit: .bytesPerSecond,
            topConsumers: model.ioTopHistory.values,
            consumerUnit: .bytes,
            secondsPerSample: model.refreshInterval
        )
    }

    private var networkPanel: some View {
        GraphPanel(
            title: "Network",
            values: model.networkHistory.values,
            color: RGBA(255, 100, 200),
            unit: .bytesPerSecond,
            topConsumers: model.networkTopHistory.values,
            consumerUnit: .bytesPerSecond,
            secondsPerSample: model.refreshInterval
        )
    }

    private var gpuPanel: some View {
        GraphPanel(
            title: "GPU Usage",
            values: model.gpuHistory.values,
            color: RGBA(150, 110, 255),
            unit: .percent,
            topConsumers: model.gpuTopHistory.values,
            consumerUnit: .percent,
            secondsPerSample: model.refreshInterval
        )
    }

    /// A responsive grid of small per-core CPU graphs.
    private var perCoreGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(model.perCoreHistory.enumerated()), id: \.offset) { index, ring in
                GraphPanel(
                    title: "Core \(index)",
                    values: ring.values,
                    color: RGBA(0, 200, 0),
                    unit: .percent,
                    secondsPerSample: model.refreshInterval,
                    compact: true
                )
            }
        }
    }
}

// MARK: - Hardware info rows

/// A titled panel of label:value hardware rows, styled to match the graph
/// panels (compact GroupBox with a headline title).
private struct InfoGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
    }
}

/// A single left-aligned label with a monospaced value on the right.
private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

// MARK: - Graph panel

/// How a numeric series is formatted for read-outs and tooltips.
enum GraphUnit {
    case percent
    case bytes
    case bytesPerSecond

    func format(_ value: Double) -> String {
        switch self {
        case .percent:
            return String(format: "%.1f%%", value)
        case .bytes:
            return ByteFormat.bytes(UInt64(Swift.max(value, 0)))
        case .bytesPerSecond:
            return ByteFormat.bytes(UInt64(Swift.max(value, 0))) + "/s"
        }
    }
}

/// A single labelled history graph with current + peak read-outs and, on hover,
/// a Procexp-style tooltip revealing the value and top consumer at that instant.
private struct GraphPanel: View {
    let title: String
    let values: [Double]
    let color: RGBA
    let unit: GraphUnit
    /// Per-sample top consumer, index-aligned with `values`. Empty when the
    /// resource has no per-process attribution (e.g. swap, per-core).
    var topConsumers: [TopConsumer] = []
    /// Unit used to format a top consumer's contribution (may differ from the
    /// graph's own unit — e.g. memory graph is a %, its consumer is bytes).
    var consumerUnit: GraphUnit? = nil
    var secondsPerSample: TimeInterval = 1
    var compact: Bool = false

    private var current: Double { values.last ?? 0 }
    private var peak: Double { values.max() ?? 0 }

    /// Upper bound for the graph. Percentages are fixed at 100; byte-based
    /// series auto-scale to the running peak with a little headroom.
    private var maxValue: Double {
        switch unit {
        case .percent:
            return 100
        case .bytes, .bytesPerSecond:
            return Swift.max(peak * 1.15, 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(compact ? .caption : .headline)
                Spacer()
                Text(unit.format(current))
                    .font(compact ? .caption : .subheadline)
                    .monospacedDigit()
                    .foregroundStyle(swiftColor)
                if !compact {
                    Text("Peak \(unit.format(peak))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HoverableGraph(
                values: values,
                maxValue: maxValue,
                color: color,
                topConsumers: topConsumers,
                unit: unit,
                consumerUnit: consumerUnit ?? unit,
                secondsPerSample: secondsPerSample,
                height: compact ? 60 : 110
            )
        }
    }

    private var swiftColor: Color {
        Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1)
    }
}

// MARK: - Hoverable graph

/// Reusable wrapper that composes a `HistoryGraphRepresentable` with a hover
/// overlay. On hover it maps the mouse X to a history index (newest sample on
/// the right), draws a vertical guide line, and floats a tooltip showing the
/// time offset, the value at that index, and the top-consuming process there.
struct HoverableGraph: View {
    let values: [Double]
    let maxValue: Double
    let color: RGBA
    var topConsumers: [TopConsumer] = []
    var unit: GraphUnit
    var consumerUnit: GraphUnit
    var secondsPerSample: TimeInterval = 1
    var height: CGFloat = 110

    @State private var hoverIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                HistoryGraphRepresentable(
                    series: [values],
                    seriesColors: [color],
                    maxValue: maxValue,
                    gridColor: RGBA(40, 40, 40),
                    backgroundColor: RGBA(12, 12, 12),
                    showGrid: true
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                )

                if let index = hoverIndex, values.indices.contains(index) {
                    let x = xPosition(for: index, width: geo.size.width)

                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: x, y: geo.size.height / 2)
                        .allowsHitTesting(false)

                    tooltip(for: index)
                        .fixedSize()
                        .position(tooltipCenter(x: x, size: geo.size))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hoverIndex = index(forX: point.x, width: geo.size.width)
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .frame(height: height)
    }

    // MARK: Hover math

    /// Map a local mouse X to the nearest sample index (0 = oldest/left,
    /// count-1 = newest/right), matching `HistoryGraphView`'s layout.
    private func index(forX x: CGFloat, width: CGFloat) -> Int {
        guard values.count > 1, width > 0 else { return values.isEmpty ? 0 : values.count - 1 }
        let fraction = Swift.min(Swift.max(x / width, 0), 1)
        return Int((fraction * CGFloat(values.count - 1)).rounded())
    }

    /// The X position of a sample index within the graph's width.
    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        guard values.count > 1 else { return width }
        return width * CGFloat(index) / CGFloat(values.count - 1)
    }

    /// Keep the tooltip on-screen: flip it to the opposite side of the guide
    /// line depending on which half of the graph the cursor is in.
    private func tooltipCenter(x: CGFloat, size: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 78
        let offset: CGFloat = x < size.width / 2 ? halfWidth + 8 : -(halfWidth + 8)
        let px = Swift.min(Swift.max(x + offset, halfWidth), size.width - halfWidth)
        return CGPoint(x: px, y: 38)
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltip(for index: Int) -> some View {
        let value = values[index]
        let secondsAgo = Double(values.count - 1 - index) * secondsPerSample
        let consumer = topConsumers.indices.contains(index) ? topConsumers[index] : nil

        VStack(alignment: .leading, spacing: 2) {
            Text(secondsAgo <= 0 ? "now" : String(format: "-%.0fs", secondsAgo))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(unit.format(value))
                .font(.caption)
                .monospacedDigit()
            if let consumer, consumer.isValid {
                Divider()
                Text("Top: \(consumer.name)")
                    .font(.caption2)
                    .lineLimit(1)
                Text(consumerUnit.format(consumer.value))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(width: 148, alignment: .leading)
        // Opaque, adaptive background + `.primary` text so the tip is legible
        // in BOTH light and dark mode (never dark-on-dark). The graph behind is
        // always a dark panel, so an opaque control-background surface with a
        // separator border and drop shadow keeps it readable and floating.
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
