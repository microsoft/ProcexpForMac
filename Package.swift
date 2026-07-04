// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProcexpMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ProcexpModel", targets: ["ProcexpModel"]),
        .library(name: "ProcexpSampling", targets: ["ProcexpSampling"]),
        .library(name: "ProcexpSigning", targets: ["ProcexpSigning"]),
        .library(name: "ProcexpNetwork", targets: ["ProcexpNetwork"]),
        .library(name: "ProcexpGraphs", targets: ["ProcexpGraphs"]),
        .library(name: "ProcexpAutostart", targets: ["ProcexpAutostart"]),
        .library(name: "ProcexpActions", targets: ["ProcexpActions"]),
        // W2 — privileged XPC client (library) + root helper daemon (executable).
        .library(name: "ProcexpPrivileged", targets: ["ProcexpPrivileged"]),
        .executable(name: "ProcexpHelper", targets: ["ProcexpHelper"]),
        // Local smoke-checker that runs without full Xcode (CLT-only) since the
        // XCTest/Testing frameworks are unavailable there. `swift run ProcexpSmoke`.
        .executable(name: "ProcexpSmoke", targets: ["ProcexpSmoke"]),
    ],
    targets: [
        .executableTarget(name: "ProcexpSmoke", dependencies: [
            "ProcexpModel", "ProcexpSampling", "ProcexpSigning",
            "ProcexpNetwork", "ProcexpGraphs", "ProcexpAutostart", "ProcexpActions",
        ]),

        // W0 — shared contracts + mock (foundation; blocks everyone)
        .target(name: "ProcexpModel"),
        .testTarget(name: "ProcexpModelTests", dependencies: ["ProcexpModel"]),

        // W1 — unprivileged sampling engine (libproc/sysctl)
        .target(name: "ProcexpSampling", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpSamplingTests", dependencies: ["ProcexpSampling"]),

        // W7 — code signing + VirusTotal
        .target(name: "ProcexpSigning", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpSigningTests", dependencies: ["ProcexpSigning"]),

        // W9 — per-process sockets + best-effort GPU
        .target(name: "ProcexpNetwork", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpNetworkTests", dependencies: ["ProcexpNetwork"]),

        // W4 — graph views + system stats
        .target(name: "ProcexpGraphs", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpGraphsTests", dependencies: ["ProcexpGraphs"]),

        // W12 — autostart detection
        .target(name: "ProcexpAutostart", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpAutostartTests", dependencies: ["ProcexpAutostart"]),

        // W8 — process actions (Phase 2)
        .target(name: "ProcexpActions", dependencies: ["ProcexpModel"]),
        .testTarget(name: "ProcexpActionsTests", dependencies: ["ProcexpActions"]),

        // W2 — privileged XPC client: connects to the root helper over
        // NSXPCConnection, registers/unregisters it via SMAppService, and
        // exposes it as a `PrivilegedSampling` provider. The app links this.
        .target(name: "ProcexpPrivileged", dependencies: ["ProcexpModel"]),

        // W2 — the privileged root daemon. Vends an NSXPCListener implementing
        // `ProcexpHelperProtocol`; reuses libproc (via ProcexpSampling's public
        // provider) for enumeration and adds task_for_pid-based thread detail.
        .executableTarget(name: "ProcexpHelper", dependencies: [
            "ProcexpModel", "ProcexpSampling", "ProcexpPrivileged",
        ]),
    ]
)
