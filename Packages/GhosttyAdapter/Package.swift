// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GhosttyAdapter",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Surface rendering and deterministic AppKit focus ownership.
        .library(name: "GhosttyAdapter", targets: ["GhosttyAdapter"]),
    ],
    dependencies: [
        // Warren owns this narrow Swift embedding layer and consumes the
        // GhosttyKit artifact published from abcdlsj/ghostty.
        .package(path: "../Vendor/GhosttyEmbedding"),
        .package(path: "../Domain"),
        .package(path: "../TerminalRenderer"),
    ],
    targets: [
        .target(
            name: "GhosttyAdapter",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "ghosttyembedding"),
                .product(name: "GhosttyKit", package: "ghosttyembedding"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenTerminalRenderer", package: "TerminalRenderer"),
            ]
        ),
        .testTarget(
            name: "GhosttyAdapterTests",
            dependencies: ["GhosttyAdapter"]
        ),
    ]
)
