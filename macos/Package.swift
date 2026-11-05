// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentsUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentsUsageKit", targets: ["AgentsUsageKit"]),
    ],
    targets: [
        .target(name: "AgentsUsageKit"),
        .executableTarget(name: "AgentsUsageBar", dependencies: ["AgentsUsageKit"]),
        .testTarget(name: "AgentsUsageKitTests", dependencies: ["AgentsUsageKit"]),
    ]
)
