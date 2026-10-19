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
            url: "https://github.com/abcdlsj/ghostty/releases/download/warren-ghosttykit-v1.0.2/GhosttyKit.xcframework.zip",
            checksum: "838ab6ac9de0bb86c34edd97390fe139f7975bcd0a09f76ef3d9497c1a6194a6"
        ),
    ]
)
