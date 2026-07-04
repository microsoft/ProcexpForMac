import Testing
@testable import ProcexpModel

@Suite("ProcexpModel W0 contracts")
struct ProcexpModelTests {

    @Test("Mock seeds a large realistic tree with launchd at the root")
    func mockProducesLargeTree() async {
        let provider = MockDataProvider()
        let snap = await provider.snapshot()
        #expect(snap.processes.count >= 140)
        #expect(!snap.roots.isEmpty)
        #expect(snap.roots.contains { $0.pid == 1 })
    }

    @Test("Tree builder computes roots and children, promoting orphans")
    func treeBuilderRootsAndChildren() {
        let root = ProcessID(pid: 1, startTime: 0)
        let child = ProcessID(pid: 2, startTime: 0)
        let orphan = ProcessID(pid: 3, startTime: 0)
        let procs: [ProcessID: ProcessRecord] = [
            root: ProcessRecord(id: root, parent: nil, name: "launchd"),
            child: ProcessRecord(id: child, parent: root, name: "child"),
            orphan: ProcessRecord(id: orphan, parent: ProcessID(pid: 99, startTime: 0), name: "orphan"),
        ]
        let (roots, children) = ProcessTreeBuilder.build(from: procs)
        #expect(roots.contains(root))
        #expect(roots.contains(orphan))
        #expect(children[root] == [child])
    }

    @Test("World evolves between consecutive snapshots")
    func snapshotDiffDetectsChange() async {
        let provider = MockDataProvider(seed: 42)
        let a = await provider.snapshot()
        var b = a
        for await snap in provider.snapshots(interval: 0.0) { b = snap; break }
        let diff = SnapshotDiff.between(a, b)
        #expect(diff.added.count + diff.changed.count > 0)
    }

    @Test("History ring keeps the newest N samples oldest-first")
    func historyRingCapacity() {
        var ring = HistoryRing<Int>(capacity: 3)
        for i in 1...5 { ring.append(i) }
        #expect(ring.values == [3, 4, 5])
        #expect(ring.latest == 5)
    }

    @Test("Byte formatting is compact and locale-stable")
    func byteFormatting() {
        #expect(ByteFormat.bytes(0) == "")
        #expect(ByteFormat.bytes(512) == "512 B")
        #expect(ByteFormat.bytes(2 * 1024 * 1024) == "2.0 M")
    }

    @Test("Columns format and produce sort keys")
    func columnFormattingAndSort() {
        let id = ProcessID(pid: 1234, startTime: 0)
        let p = ProcessRecord(id: id, name: "Safari", cpuPercent: 12.5,
                            threadCount: 8, residentSize: 100 * 1024 * 1024)
        #expect(Column.pid.string(for: p) == "1234")
        #expect(Column.name.string(for: p) == "Safari")
        #expect(Column.cpu.string(for: p) == "12.50")
        #expect(Column.threads.string(for: p) == "8")
        #expect(Column.cpu.sortValue(for: p) == .number(12.5))
    }

    @Test("New/dead colors take priority over own-process color")
    func colorRulePriority() {
        let bg = ProcessColorRule.background(
            for: [.ownProcess, .newProcess],
            rules: ProcessColorRule.defaults,
            darkMode: false)
        let newColor = ProcessColorRule.defaults.first { $0.flag == .newProcess }!.backgroundLight
        #expect(bg == newColor)
    }

    @Test("Process identity survives PID reuse")
    func processIdentityStable() {
        let a = ProcessID(pid: 500, startTime: 100)
        let b = ProcessID(pid: 500, startTime: 200)
        #expect(a != b)
    }
}
