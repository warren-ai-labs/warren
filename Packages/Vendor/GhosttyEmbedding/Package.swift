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
            url: "https://github.com/abcdlsj/ghostty/releases/download/warren-ghosttykit-v1.0.0/GhosttyKit.xcframework.zip",
            checksum: "ddc36b7b093e7d34b01596c9b5c1093a780aa1a828186428693aeaef723a5220"
        ),
    ]
)
