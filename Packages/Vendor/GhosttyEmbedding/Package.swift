// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WarrenGhosttyEmbedding",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit"],
            path: "Sources/GhosttyTerminal"
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/abcdlsj/ghostty/releases/download/warren-ghosttykit-v1.1.0/GhosttyKit.xcframework.zip",
            checksum: "3180df05715203158c25d76dc3e7c091dd6313cf6f8228e85eb830c27a66155d"
        ),
    ]
)
