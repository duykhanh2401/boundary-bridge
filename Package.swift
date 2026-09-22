// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoundaryBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "BoundaryBridge", targets: ["BoundaryBridge"])
    ],
    targets: [
        .target(name: "BridgeCore", resources: [.copy("Resources")]),
        .executableTarget(name: "BridgeIcon", path: "Tools/IconGenerator"),
        .executableTarget(name: "BrowserChecks", dependencies: ["BridgeCore"], path: "Tests/BrowserChecks"),
        .executableTarget(name: "BoundaryBridge", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeChecks", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests",
                    resources: [.copy("Fixtures")])
    ]
)
