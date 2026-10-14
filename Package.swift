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
        .target(name: "MochiVAD", path: "Vendor/libfvad", sources: ["src"], publicHeadersPath: "include"),
        .target(name: "MochiCore", dependencies: ["MochiKernel", "MochiVAD"]),
        .target(name: "MochiProviders", dependencies: ["MochiKernel", "MochiAutomation", "MochiCore"]),
        .executableTarget(name: "MochiMCP", dependencies: ["MochiAutomation"]),
        .executableTarget(
            name: "MochiApp", dependencies: ["MochiKernel", "MochiAutomation", "MochiCore", "MochiProviders"],
            resources: [.process("Resources")],
            swiftSettings: [.define("MOCHI_DEVELOPMENT", .when(configuration: .debug))]),
        .target(name: "MochiTestSupport", path: "Tests/MochiTestSupport", resources: [.copy("Resources")]),
        .testTarget(name: "MochiKernelTests", dependencies: ["MochiKernel"]),
        .testTarget(
            name: "MochiAutomationTests", dependencies: ["MochiKernel", "MochiAutomation", "MochiTestSupport"]),
        .testTarget(name: "MochiCoreTests", dependencies: ["MochiKernel", "MochiCore", "MochiTestSupport"]),
        .testTarget(
            name: "MochiProvidersTests",
            dependencies: ["MochiKernel", "MochiCore", "MochiProviders", "MochiTestSupport"]),
        .testTarget(
            name: "MochiAppTests",
            dependencies: [
                "MochiKernel", "MochiAutomation", "MochiApp", "MochiCore", "MochiProviders", "MochiTestSupport",
            ]),
    ])
