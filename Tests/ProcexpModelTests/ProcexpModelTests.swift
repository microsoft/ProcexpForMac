import Testing
import Foundation
@testable import ProcexpModel

@Suite("ProcexpModel W0 contracts")
struct ProcexpModelTests {

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

    @Test("Snapshot diff detects added removed and changed records")
    func snapshotDiffDetectsChange() {
        let id1 = ProcessID(pid: 1, startTime: 10)
        let id2 = ProcessID(pid: 2, startTime: 20)
        let id3 = ProcessID(pid: 3, startTime: 30)
        let old = ProcessSnapshot(
            timestamp: .distantPast,
            interval: 1,
            processes: [
                id1: ProcessRecord(id: id1, name: "one", cpuPercent: 1),
                id2: ProcessRecord(id: id2, name: "two"),
            ],
            roots: [id1, id2],
            children: [:],
            system: .zero
        )
        let new = ProcessSnapshot(
            timestamp: Date(),
            interval: 1,
            processes: [
                id1: ProcessRecord(id: id1, name: "one", cpuPercent: 2),
                id3: ProcessRecord(id: id3, name: "three"),
            ],
            roots: [id1, id3],
            children: [:],
            system: .zero
        )
        let diff = SnapshotDiff.between(old, new)
        #expect(diff.added == [id3])
        #expect(diff.removed == [id2])
        #expect(diff.changed == [id1])
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

    @Test("Extended taskinfo columns format and sort")
    func extendedTaskInfoColumns() {
        let id = ProcessID(pid: 4321, startTime: 0)
        let p = ProcessRecord(
            id: id,
            name: "tool",
            bsdFlagsRaw: 0x40,
            runningThreadCount: 3,
            threadUserTime: 2_000_000_000,
            threadSystemTime: 1_000_000_000,
            taskPolicy: 2,
            pageIns: 7,
            copyOnWriteFaults: 11,
            machMessagesSent: 13,
            machMessagesReceived: 17,
            machSyscalls: 19,
            unixSyscalls: 23
        )

        #expect(Column.runningThreads.string(for: p) == "3")
        #expect(Column.threadUserTime.string(for: p) == "0:00:02.00")
        #expect(Column.threadSystemTime.string(for: p) == "0:00:01.00")
        #expect(Column.pageIns.sortValue(for: p) == .number(7))
        #expect(Column.cowFaults.sortValue(for: p) == .number(11))
        #expect(Column.machSyscalls.string(for: p) == "19")
        #expect(Column.unixSyscalls.string(for: p) == "23")
        #expect(Column.bsdFlags.string(for: p) == "0x00000040")
    }

    @Test("Extended taskinfo columns are blank when task info is limited")
    func extendedTaskInfoColumnsLimited() {
        let p = ProcessRecord(
            id: ProcessID(pid: 99, startTime: 0),
            name: "limited",
            runningThreadCount: 3,
            flags: [.limitedTaskInfo]
        )

        #expect(Column.runningThreads.string(for: p) == "")
        #expect(Column.runningThreads.sortValue(for: p) == .none)
        #expect(Column.pageIns.string(for: p) == "")
        #expect(Column.machSyscalls.sortValue(for: p) == .none)
    }

    @Test("Unsupported macOS columns are excluded from selectable columns")
    func unsupportedColumnsExcluded() {
        let unsupported: Set<Column> = [.network, .gpu, .gpuMemory, .integrity]
        #expect(unsupported.isDisjoint(with: Set(Column.supportedOnMac)))
        #expect(Column.supportedOnMac.contains(.commandLine))
    }

    @Test("PID is a pinned process-list column")
    func pidColumnIsPinned() {
        #expect(Column.pinnedOnMac == [.name, .pid])
        #expect(Column.supportedOnMac.contains(.pid))
    }

    @Test("Lower-pane column defaults mirror Windows visible defaults")
    func lowerPaneColumnDefaults() {
        #expect(ModuleColumn.defaultColumns == [.name, .description, .company, .path])
        #expect(HandleColumn.defaultColumns == [.kind, .name, .fd])
        #expect(ThreadColumn.defaultColumns == [
            .state, .tid, .userTime, .kernelTime, .cpu, .cpuTime,
            .startAddress, .basePriority, .currentPriority,
        ])
    }

    @Test("Lower-pane column metadata supplies titles widths and alignment")
    func lowerPaneColumnMetadata() {
        #expect(ModuleColumn.base.isRightAligned)
        #expect(ModuleColumn.path.title == "Path")
        #expect(HandleColumn.fd.title == "FD")
        #expect(HandleColumn.fd.isRightAligned)
        #expect(ThreadColumn.currentPriority.title == "Cur Pri")
        #expect(ThreadColumn.state.defaultWidth > 0)
    }

    @Test("Lower-pane flag formatters include names and raw values")
    func lowerPaneFlagFormatters() {
        #expect(FileDescriptorFlagFormatter.status(0x6) == "Close-on-exec, Guarded (0x6)")
        #expect(FileDescriptorFlagFormatter.status(nil) == "")
        #expect(FileDescriptorFlagFormatter.guardFlags(0x3) == "Close, Dup (0x3)")
        #expect(ThreadFlagFormatter.flags(0x3) == "Swapped, Idle (0x3)")
        #expect(ThreadFlagFormatter.flags(0) == "")
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
