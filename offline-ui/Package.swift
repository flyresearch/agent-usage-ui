// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AgentUsageOffline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentUsage", targets: ["AgentUsage"]), .executable(name: "UsageCoreCheck", targets: ["UsageCoreCheck"])],
    targets: [
        .target(name: "UsageCore", resources:[.copy("Resources")]),
        .executableTarget(name: "AgentUsage", dependencies: ["UsageCore"]),
        .executableTarget(name: "UsageCoreCheck", dependencies: ["UsageCore"], path: "Tests/UsageCoreTests")
    ]
)
