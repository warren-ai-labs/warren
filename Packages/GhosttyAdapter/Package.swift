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
        // Vendored because the embedder must answer the Ghostty open-url
        // action synchronously (see docs/lessons.md #002); upstream
        // libghostty-swift is still at storage.1.0.16 and has no fix.
        .package(path: "../Vendor/libghostty-swift"),
        .package(path: "../Domain"),
        .package(path: "../TerminalRenderer"),
    ],
    targets: [
        .target(
            name: "GhosttyAdapter",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-swift"),
                .product(name: "GhosttyKit", package: "libghostty-swift"),
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
