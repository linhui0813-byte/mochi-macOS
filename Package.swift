// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mochi", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mochi", targets: ["MochiApp"]), .executable(name: "mochi-mcp", targets: ["MochiMCP"]),
    ],
    targets: [
        .target(name: "MochiKernel"),
        .target(name: "MochiAutomation", dependencies: ["MochiKernel"]),
        .target(name: "MochiCore", dependencies: ["MochiKernel", "MochiAutomation"]),
        .executableTarget(name: "MochiMCP", dependencies: ["MochiAutomation"]),
        .executableTarget(
            name: "MochiApp", dependencies: ["MochiKernel", "MochiAutomation", "MochiCore"],
            resources: [.process("Resources")],
            swiftSettings: [.define("MOCHI_DEVELOPMENT", .when(configuration: .debug))]),
        .target(name: "MochiTestSupport", path: "Tests/MochiTestSupport"),
        .testTarget(
            name: "MochiCoreTests", dependencies: ["MochiKernel", "MochiAutomation", "MochiCore", "MochiTestSupport"]),
        .testTarget(
            name: "MochiAppTests",
            dependencies: ["MochiKernel", "MochiAutomation", "MochiApp", "MochiCore", "MochiTestSupport"]),
    ])
