import Testing
import ProcexpModel
@testable import ProcexpGraphs

@Suite("W4 Graphs + SystemStats")
struct ProcexpGraphsTests {

    @Test("Reads real system memory and per-core CPU")
    func systemStats() async {
        let provider = SystemStatsProvider()
        _ = await provider.stats()                     // prime CPU deltas
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stats = await provider.stats()
        #expect(stats.memoryTotal > 0)
        #expect(!stats.perCoreCPUPercent.isEmpty)
        #expect(stats.diskBytesPerSec >= 0)
        for core in stats.perCoreCPUPercent { #expect(core >= 0 && core <= 100) }
    }

    @MainActor
    @Test("Sparkline view can be constructed and accepts data")
    func sparklineConstructs() {
        let view = SparklineView(frame: .init(x: 0, y: 0, width: 100, height: 20))
        view.values = [0, 25, 50, 75, 100]
        view.maxValue = 100
        #expect(view.values.count == 5)
    }
}
