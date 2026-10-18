// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Still", targets: ["Still"]), .executable(name: "StillHelper", targets: ["StillHelper"])],
    targets: [
        .target(name: "BlockerCore"),
        .target(name: "BlockerAuthorization", dependencies: ["BlockerCore"]),
        .target(name: "BlockerSystem", dependencies: ["BlockerCore", "BlockerAuthorization"]),
        .executableTarget(name: "StillHelper", dependencies: ["BlockerCore", "BlockerSystem", "BlockerAuthorization"]),
        .executableTarget(name: "Still", dependencies: ["BlockerCore", "BlockerAuthorization"]),
        .testTarget(name: "BlockerCoreTests", dependencies: ["BlockerCore"]),
        .testTarget(name: "BlockerAuthorizationTests", dependencies: ["BlockerAuthorization", "BlockerCore"]),
        .testTarget(name: "StillTests", dependencies: ["Still", "BlockerCore"]),
        .testTarget(name: "BlockerSystemTests", dependencies: ["BlockerCore", "BlockerSystem"])
    ]
)
