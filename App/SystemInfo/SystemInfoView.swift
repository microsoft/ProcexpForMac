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
    @Environment(\.dismiss) private var dismiss

    /// Static hardware description, gathered once and cached.
    private let hardware = HardwareInfo.current

    private let tabs: [SystemInfoTab] = [.summary, .cpu, .memory, .io, .network, .gpu]

    var body: some View {
        @Bindable var model = model
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: $model.systemInfoTab) {
                    ForEach(tabs, id: \.self) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 620)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()

                tabContent
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(EscapeKeyMonitor { dismiss() })
    }

    @ViewBuilder private var tabContent: some View {
        switch model.systemInfoTab {
        case .summary: summaryTab
        case .cpu: cpuTab
        case .memory: memoryTab
        case .io: ioTab
        case .network: networkTab
        case .gpu: gpuTab
        }
    }

    private func tabTitle(_ tab: SystemInfoTab) -> String {
        switch tab {
        case .summary: return "Summary"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .io: return "I/O"
        case .network: return "Network"
        case .gpu: return "GPU"
        }
    }

    // MARK: - Tabs

    private var summaryTab: some View {
        VStack(spacing: 12) {
            InfoPanelGrid {
                hardwareSummaryPanel
                storageHardwarePanel
            }
            FillGraphArea(graphCount: 2) { graphHeight in
                GraphGrid(minHeight: graphHeight, minWidth: 260) {
                    cpuTotalPanel(graphHeight: graphHeight)
                    memoryPanel(graphHeight: graphHeight)
                    swapPanel(graphHeight: graphHeight)
                    diskPanel(graphHeight: graphHeight)
                    networkPanel(graphHeight: graphHeight)
                    gpuPanel(graphHeight: graphHeight)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cpuTab: some View {
        VStack(spacing: 12) {
            cpuHardwarePanel
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                let coreCount = model.perCoreHistory.count
                let columns = max(1, Int((geo.size.width + 12) / 162))
                let coreRows = max(1, Int(ceil(Double(coreCount) / Double(columns))))
                let totalHeight = coreCount == 0 ? geo.size.height : max(64, min(112, geo.size.height * 0.24))
                let labelHeight: CGFloat = coreCount == 0 ? 0 : 22
                let verticalSpacing = CGFloat(max(coreRows - 1, 0)) * 12
                let coreHeight = max(28, (geo.size.height - totalHeight - labelHeight - 24 - verticalSpacing) / CGFloat(coreRows))
                VStack(spacing: 12) {
                    cpuTotalPanel(graphHeight: totalHeight)
                    if coreCount > 0 {
                        Text("Per-Core Usage")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        perCoreGrid(graphHeight: coreHeight)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var memoryTab: some View {
        VStack(spacing: 12) {
            memoryHardwarePanel
                .fixedSize(horizontal: false, vertical: true)
            FillGraphArea(graphCount: 2) { graphHeight in
                VStack(spacing: 12) {
                    memoryPanel(graphHeight: graphHeight)
                    swapPanel(graphHeight: graphHeight)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var ioTab: some View {
        VStack(spacing: 12) {
            storageHardwarePanels
                .fixedSize(horizontal: false, vertical: true)
            FillGraphArea(graphCount: 1) { graphHeight in
                diskPanel(graphHeight: graphHeight)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var networkTab: some View {
        VStack(spacing: 12) {
            networkHardwarePanel
                .fixedSize(horizontal: false, vertical: true)
            FillGraphArea(graphCount: 1) { graphHeight in
                networkPanel(graphHeight: graphHeight)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var gpuTab: some View {
        VStack(spacing: 12) {
            gpuHardwarePanel
                .fixedSize(horizontal: false, vertical: true)
            FillGraphArea(graphCount: max(1, hardware.gpus.count)) { graphHeight in
                gpuPanel(graphHeight: graphHeight)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            InfoRow("Page Size", ByteFormat.bytes(hardware.pageSize))
            if let gpu = hardware.gpus.first {
                InfoRow("GPU", gpuLabel(gpu))
            }
            InfoRow("Network Interfaces", "\(hardware.networkInterfaces.count)")
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
            if let cacheLine = hardware.cacheLineSize { InfoRow("Cache Line", ByteFormat.bytes(cacheLine)) }
            if let l1i = hardware.l1InstructionCache { InfoRow("L1 I-Cache", ByteFormat.bytes(l1i)) }
            if let l1d = hardware.l1DataCache { InfoRow("L1 D-Cache", ByteFormat.bytes(l1d)) }
            if let l2 = hardware.l2Cache { InfoRow("L2 Cache", ByteFormat.bytes(l2)) }
            if let l3 = hardware.l3Cache { InfoRow("L3 Cache", ByteFormat.bytes(l3)) }
            InfoRow("Architecture", hardware.architecture)
        }
    }

    /// Memory tab detail: installed RAM, page size.
    private var memoryHardwarePanel: some View {
        InfoGroup(title: "Physical Memory") {
            InfoRow("Installed", ByteFormat.bytes(hardware.physicalMemory))
            InfoRow("Page Size", ByteFormat.bytes(hardware.pageSize))
            InfoRow("Page Count", "\(hardware.physicalMemory / max(hardware.pageSize, 1))")
            if let gpu = hardware.gpus.first, let vram = gpu.vram, gpu.unifiedMemory {
                InfoRow("GPU Working Set", ByteFormat.bytes(vram))
            }
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
                    InfoRow("Registry ID", String(format: "0x%llX", gpu.registryID))
                    InfoRow("Max Threads", gpu.maxThreadsPerThreadgroup)
                    InfoRow("Max Buffer", ByteFormat.bytes(gpu.maxBufferLength))
                    InfoRow("Argument Buffers", gpu.argumentBuffersTier)
                    InfoRow("Read/Write Textures", gpu.readWriteTextureTier)
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
                if let format = volume.formatDescription { InfoRow("Format", format) }
                if let internalDisk = volume.isInternal { InfoRow("Internal", yesNo(internalDisk)) }
                if let removable = volume.isRemovable { InfoRow("Removable", yesNo(removable)) }
                if let ejectable = volume.isEjectable { InfoRow("Ejectable", yesNo(ejectable)) }
                if let readOnly = volume.isReadOnly { InfoRow("Read-Only", yesNo(readOnly)) }
            } else {
                InfoRow("Boot Volume", "Unavailable")
            }
        }
    }

    private var storageHardwarePanels: some View {
        InfoPanelGrid {
            ForEach(Array(hardware.volumes.enumerated()), id: \.offset) { _, volume in
                volumePanel(volume)
            }
        }
    }

    private func volumePanel(_ volume: HardwareInfo.VolumeInfo) -> some View {
        InfoGroup(title: volume.name) {
            InfoRow("Type", volume.mediaType)
            InfoRow("Capacity", ByteFormat.bytes(volume.totalCapacity))
            InfoRow("Available", ByteFormat.bytes(volume.availableCapacity))
            InfoRow("Used", ByteFormat.bytes(volume.totalCapacity - volume.availableCapacity))
            if let format = volume.formatDescription { InfoRow("Format", format) }
            if let internalDisk = volume.isInternal { InfoRow("Internal", yesNo(internalDisk)) }
            if let removable = volume.isRemovable { InfoRow("Removable", yesNo(removable)) }
            if let ejectable = volume.isEjectable { InfoRow("Ejectable", yesNo(ejectable)) }
            if let readOnly = volume.isReadOnly { InfoRow("Read-Only", yesNo(readOnly)) }
        }
    }

    private var networkHardwarePanel: some View {
        InfoGroup(title: "Interfaces") {
            if hardware.networkInterfaces.isEmpty {
                InfoRow("Interfaces", "Unavailable")
            } else {
                ForEach(hardware.networkInterfaces) { interface in
                    InfoRow(interface.name, "\(interface.families.joined(separator: "/")) \(interface.addresses.joined(separator: ", ")) • \(interfaceFlags(interface))", labelWidth: 56)
                }
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

    private func interfaceFlags(_ interface: HardwareInfo.NetworkInterfaceInfo) -> String {
        var parts: [String] = []
        parts.append(interface.isUp ? "Up" : "Down")
        if interface.isRunning { parts.append("Running") }
        if interface.isLoopback { parts.append("Loopback") }
        return parts.joined(separator: " • ")
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func volumeLabel(_ volume: HardwareInfo.VolumeInfo) -> String {
        let free = ByteFormat.bytes(volume.availableCapacity)
        let total = ByteFormat.bytes(volume.totalCapacity)
        return "\(volume.name) — \(free) free of \(total) (\(volume.mediaType))"
    }


    // MARK: - Panels

    private func cpuTotalPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "CPU Usage (Total)",
            values: model.cpuHistory.values,
            color: RGBA(0, 200, 0),
            unit: .percent,
            topConsumers: model.cpuTopHistory.values,
            consumerUnit: .percent,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    private func memoryPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "Physical Memory",
            values: model.memoryHistory.values,
            color: RGBA(230, 90, 90),
            unit: .percent,
            topConsumers: model.memoryTopHistory.values,
            consumerUnit: .bytes,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    private func swapPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "Swap Used",
            values: model.swapHistory.values,
            color: RGBA(255, 180, 0),
            unit: .bytes,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    private func diskPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "Disk I/O",
            values: model.diskHistory.values,
            color: RGBA(0, 160, 255),
            unit: .bytesPerSecond,
            topConsumers: model.ioTopHistory.values,
            consumerUnit: .bytes,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    private func networkPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "Network",
            values: model.networkHistory.values,
            color: RGBA(255, 100, 200),
            unit: .bytesPerSecond,
            topConsumers: model.networkTopHistory.values,
            consumerUnit: .bytesPerSecond,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    private func gpuPanel(graphHeight: CGFloat? = nil) -> some View {
        GraphPanel(
            title: "GPU Usage",
            values: model.gpuHistory.values,
            color: RGBA(150, 110, 255),
            unit: .percent,
            topConsumers: model.gpuTopHistory.values,
            consumerUnit: .percent,
            timestamps: model.systemHistoryTimestamps.values,
            graphHeight: graphHeight
        )
    }

    /// A responsive grid of small per-core CPU graphs.
    private func perCoreGrid(graphHeight: CGFloat? = nil) -> some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(model.perCoreHistory.enumerated()), id: \.offset) { index, ring in
                GraphPanel(
                    title: coreTitle(index),
                    values: ring.values,
                    color: coreColor(index),
                    unit: .percent,
                    timestamps: model.systemHistoryTimestamps.values,
                    graphHeight: graphHeight,
                    compact: true
                )
            }
        }
    }

    private func coreTitle(_ index: Int) -> String {
        switch coreKind(index) {
        case "P": return "P-Core \(index)"
        case "E": return "E-Core \(index)"
        default: return "Core \(index)"
        }
    }

    private func coreColor(_ index: Int) -> RGBA {
        switch coreKind(index) {
        case "P": return RGBA(0, 200, 0)
        case "E": return RGBA(0, 145, 220)
        default: return RGBA(0, 200, 0)
        }
    }

    private func coreKind(_ index: Int) -> String? {
        guard let performance = hardware.performanceCores,
              let efficiency = hardware.efficiencyCores,
              performance + efficiency > 0 else { return nil }
        if index < performance { return "P" }
        if index < performance + efficiency { return "E" }
        return nil
    }
}

// MARK: - Hardware info rows

private struct InfoPanelGrid<Content: View>: View {
    @ViewBuilder var content: Content

    private let columns = [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            content
        }
    }
}

private struct GraphGrid<Content: View>: View {
    var minHeight: CGFloat
    var minWidth: CGFloat = 430
    @ViewBuilder var content: Content

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: minWidth), spacing: 12, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            content
                .frame(height: minHeight, alignment: .top)
        }
    }
}

private struct FillGraphArea<Content: View>: View {
    let graphCount: Int
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = max(0, CGFloat(max(graphCount - 1, 0)) * 12)
            let graphHeight = max(40, (geo.size.height - spacing) / CGFloat(max(graphCount, 1)))
            content(graphHeight)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 3
                ) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single left-aligned label with a monospaced value on the right.
private struct InfoRow: View {
    let label: String
    let value: String
    let labelWidth: CGFloat

    init(_ label: String, _ value: String, labelWidth: CGFloat = 120) {
        self.label = label
        self.value = value
        self.labelWidth = labelWidth
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
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
    var timestamps: [Date] = []
    var graphHeight: CGFloat? = nil
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
        let headerReserve: CGFloat = compact ? 18 : 28
        let canvasHeight = graphHeight.map { max(compact ? 20 : 40, $0 - headerReserve) } ?? (compact ? 60 : 110)
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
                timestamps: timestamps,
                height: canvasHeight
            )
        }
        .frame(height: graphHeight, alignment: .top)
        .clipped()
    }

    private var swiftColor: Color {
        Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1)
    }
}

// MARK: - Hoverable graph

/// Reusable wrapper that composes a `HistoryGraphRepresentable` with a hover
/// overlay. On hover it maps the mouse X to a history index (newest sample on
/// the right), draws a vertical guide line, and floats a tooltip showing the
/// timestamp, the value at that index, and the top-consuming process there.
struct HoverableGraph: View {
    let values: [Double]
    let maxValue: Double
    let color: RGBA
    var topConsumers: [TopConsumer] = []
    var unit: GraphUnit
    var consumerUnit: GraphUnit
    var timestamps: [Date] = []
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
        let consumer = topConsumers.indices.contains(index) ? topConsumers[index] : nil

        VStack(alignment: .leading, spacing: 2) {
            Text(timestampText(for: index))
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

    private func timestampText(for index: Int) -> String {
        guard let date = timestamp(for: index) else { return "—" }
        return Self.timeFormatter.string(from: date)
    }

    private func timestamp(for index: Int) -> Date? {
        guard !values.isEmpty, !timestamps.isEmpty else { return nil }
        let offsetFromNewest = values.count - 1 - index
        let timestampIndex = timestamps.count - 1 - offsetFromNewest
        return timestamps.indices.contains(timestampIndex) ? timestamps[timestampIndex] : nil
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
