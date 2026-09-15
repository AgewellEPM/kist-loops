// swift-tools-version:5.9
import PackageDescription

// AgentCore: the cross-platform (macOS + Linux) brain shared by the GUI app, the Kist terminal app,
// and mcp-server. Foundation-only except for swift-crypto (apple/swift-crypto = the cross-platform
// CryptoKit API, BoringSSL-backed on Linux) — needed by the fleet trust layer (forge-proof signoff
// HMAC, Ed25519 deploy gate). It's our only external dependency; pinned via Package.resolved.
let package = Package(
    name: "AgentCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "kist", targets: ["Kist"]),
        // kist-control: the privileged desktop broker (split-identity L2). Separately built/signed so the
        // coding `kist` never holds Accessibility/Screen-Recording; talks to it over an authenticated socket.
        .executable(name: "kist-control", targets: ["KistControl"]),
        // DesignFlow: headless autonomous design→code loop, shipped inside kist so a
        // single clone/build yields both binaries. Self-contained (Foundation-only)
        // for now; a later pass folds its gate/commit discipline onto the fleet engine.
        .executable(name: "designflow", targets: ["designflow"]),
        .library(name: "DesignFlowKit", targets: ["DesignFlowKit"]),
        // ConnectorKit: the universal AI-driven connector layer (REST manifests + MCP
        // refs, sealed audit history, auto-tuner). Reusable by kist.
        .library(name: "ConnectorKit", targets: ["ConnectorKit"]),
        // DockerControl: auto-configure + safely drive Docker sandboxes (name-scoped,
        // resource-capped, non-privileged). Reusable by kist.
        .library(name: "DockerControl", targets: ["DockerControl"]),
        // TagTeamKit: build → tag-team review (N pluggable reviewers) → fix-all.
        .library(name: "TagTeamKit", targets: ["TagTeamKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.1"),
    ],
    targets: [
        .target(name: "AgentCore",
                dependencies: [.product(name: "Crypto", package: "swift-crypto"),
                               .product(name: "CoreXLSX", package: "CoreXLSX")],
                exclude: ["SECURITY.md"],
                resources: [.copy("Skills/builtin")]),
        .executableTarget(name: "Kist", dependencies: ["AgentCore"]),
        .executableTarget(name: "KistControl", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "KistTests", dependencies: ["Kist"]),
        // DesignFlow module. Depends on AgentCore to reuse the hardened trust
        // primitives (GitIsolation committed-diff measurement, ClaimReconciler) rather
        // than maintain a duplicate git/gate layer. It does NOT depend on Kist.
        .target(name: "DesignFlowKit", dependencies: ["AgentCore"]),
        .target(name: "ConnectorKit", dependencies: ["AgentCore"]),
        .target(name: "DockerControl"),
        .target(name: "TagTeamKit", dependencies: ["AgentCore"]),
        .executableTarget(name: "designflow", dependencies: ["AgentCore", "DesignFlowKit", "ConnectorKit", "DockerControl", "TagTeamKit"]),
        .testTarget(name: "DesignFlowKitTests", dependencies: ["DesignFlowKit"]),
        .testTarget(name: "ConnectorKitTests", dependencies: ["ConnectorKit"]),
        .testTarget(name: "DockerControlTests", dependencies: ["DockerControl"]),
        .testTarget(name: "TagTeamKitTests", dependencies: ["TagTeamKit"]),
    ]
)
