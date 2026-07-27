// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fca-mcp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "fca-mcp",
            path: "Sources/fca-mcp"
        )
    ]
)
