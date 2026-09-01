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
            url: "https://github.com/abcdlsj/ghostty/releases/download/warren-ghosttykit-v1.0.1/GhosttyKit.xcframework.zip",
            checksum: "741d9757eb5f74ca5ef83055ffaed447794be0edb31a45f26b2a53c46bb22099"
        ),
    ]
)
