// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Still", targets: ["Still"]), .executable(name: "StillHelper", targets: ["StillHelper"])],
    targets: [
        .target(name: "BlockerCore"),
        .target(name: "BlockerSystem", dependencies: ["BlockerCore"]),
        .executableTarget(name: "StillHelper", dependencies: ["BlockerCore", "BlockerSystem"]),
        .executableTarget(name: "Still", dependencies: ["BlockerCore"]),
        .testTarget(name: "BlockerCoreTests", dependencies: ["BlockerCore"]),
        .testTarget(name: "BlockerSystemTests", dependencies: ["BlockerCore", "BlockerSystem"])
    ]
)
