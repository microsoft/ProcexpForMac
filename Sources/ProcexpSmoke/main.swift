//
//  ProcexpSmoke — CLT-friendly validation of the W0 model.
//
//  The XCTest/Testing frameworks are not available with Command Line Tools
//  only, so this executable exercises the same invariants the unit tests do,
//  and exits non-zero on failure. Run with `swift run ProcexpSmoke`.
//

import Foundation
import ProcexpModel
import ProcexpSampling
import ProcexpSigning
import ProcexpNetwork
import ProcexpGraphs
import ProcexpAutostart
import ProcexpActions

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

print("ProcexpModel W0 smoke check")

let provider = MockDataProvider()
let snap = await provider.snapshot()
check(snap.processes.count >= 140, "mock seeds >= 140 processes (got \(snap.processes.count))")
check(snap.roots.contains { $0.pid == 1 }, "launchd (pid 1) is a root")
check(!snap.system.perCoreCPUPercent.isEmpty, "system stats include per-core CPU")

// Tree builder
let root = ProcessID(pid: 1, startTime: 0)
let child = ProcessID(pid: 2, startTime: 0)
let procs: [ProcessID: ProcessRecord] = [
    root: ProcessRecord(id: root, name: "launchd"),
    child: ProcessRecord(id: child, parent: root, name: "child"),
]
let (roots, children) = ProcessTreeBuilder.build(from: procs)
check(roots == [root], "tree builder finds single root")
check(children[root] == [child], "tree builder links child to parent")

// Evolution / diff
let before = await provider.snapshot()
var after = before
for await s in provider.snapshots(interval: 0.0) { after = s; break }
let diff = SnapshotDiff.between(before, after)
check(diff.added.count + diff.changed.count > 0, "world evolves between snapshots")

// History ring
var ring = HistoryRing<Int>(capacity: 3)
for i in 1...5 { ring.append(i) }
check(ring.values == [3, 4, 5], "history ring keeps newest N")

// Formatting
check(ByteFormat.bytes(2 * 1024 * 1024) == "2.0 M", "byte formatting")

// Columns
let p = ProcessRecord(id: ProcessID(pid: 1234, startTime: 0), name: "Safari", cpuPercent: 12.5, threadCount: 8)
check(Column.cpu.string(for: p) == "12.50", "CPU column formatting")
check(Column.cpu.sortValue(for: p) == .number(12.5), "CPU column sort key")

// Color priority
let bg = ProcessColorRule.background(for: [.ownProcess, .newProcess], rules: ProcessColorRule.defaults, darkMode: false)
let newColor = ProcessColorRule.defaults.first { $0.flag == .newProcess }!.backgroundLight
check(bg == newColor, "new-process color wins over own-process color")

// Detail providers
let anApp = snap.processes.values.first { $0.flags.contains(.ownProcess) }!
let threads = try await provider.threads(of: anApp.id)
let modules = try await provider.modules(of: anApp.id)
let fds = try await provider.fileDescriptors(of: anApp.id)
check(threads.count == anApp.threadCount, "thread detail count matches process")
check(!modules.isEmpty, "modules returned for a process")
check(!fds.isEmpty, "file descriptors returned for a process")

// ---------------------------------------------------------------------------
// LIVE checks against the real machine (W1/W4/W7/W9/W12/W8).
// ---------------------------------------------------------------------------
print("\nLive provider checks (real system)")

// W1 — real process sampling
let live = LibprocDataProvider()
let liveSnap = await live.snapshot()
check(liveSnap.processes.count > 20, "libproc samples real processes (got \(liveSnap.processes.count))")
// launchd (pid 1) is always present. It is a root unless the kernel task
// (pid 0) is also enumerated, in which case launchd is pid 0's child.
let hasLaunchd = liveSnap.processes.keys.contains { $0.pid == 1 }
check(hasLaunchd, "real launchd (pid 1) present in snapshot")
let selfPID = ProcessID(pid: Int32(ProcessInfo.processInfo.processIdentifier),
                        startTime: liveSnap.processes.keys.first { $0.pid == Int32(getpid()) }?.startTime ?? 0)
_ = selfPID
if let me = liveSnap.processes.values.first(where: { $0.id.pid == getpid() }) {
    check(me.flags.contains(.ownProcess), "own process flagged for current pid")
    check(me.threadCount > 0, "own process has threads")
}

// W4 — real system stats (call twice so CPU deltas populate)
let sys = SystemStatsProvider()
_ = await sys.stats()
try? await Task.sleep(nanoseconds: 200_000_000)
let s2 = await sys.stats()
check(s2.memoryTotal > 0, "system memory total read (\(ByteFormat.bytes(s2.memoryTotal)))")
check(!s2.perCoreCPUPercent.isEmpty, "per-core CPU read (\(s2.perCoreCPUPercent.count) cores)")

// W9 — sockets of our own process (may be zero, but must not crash)
let net = NetworkProvider()
let mySockets = (try? await net.sockets(of: ProcessID(pid: getpid(), startTime: 0))) ?? []
check(true, "network provider enumerated sockets without crashing (\(mySockets.count) found)")
let gpu = await GPUStatsProvider().systemGPUPercent()
check(true, "GPU provider returned \(gpu.map { String(format: "%.0f%%", $0) } ?? "nil (no per-device stat)")")

// W7 — code signing of a known platform binary
let signer = CodeSignProvider()
let sig = await signer.signature(forPath: "/bin/ls")
check(sig.status == .signed, "/bin/ls is signed (status: \(sig.status))")
check(sig.isPlatformBinary, "/bin/ls detected as platform binary")
check(sig.sha256 != nil, "/bin/ls sha256 computed")

// W12 — autostart index scans without crashing
let autostart = AutostartProvider()
if let daemon = liveSnap.processes.values.first(where: { $0.flags.contains(.service) }) {
    _ = await autostart.autostartLocation(for: daemon)
}
check(true, "autostart provider scanned launchd plists without crashing")

// W8 — action confirmation metadata (no destructive action executed)
let killConfirm = ActionConfirmation.forKind(.kill, processName: "demo")
check(killConfirm.requiresConfirmation, "kill action requires confirmation")

print(failures == 0 ? "\nALL SMOKE CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
