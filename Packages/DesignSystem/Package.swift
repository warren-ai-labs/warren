// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenDesignSystem",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenDesignSystem", targets: ["WarrenDesignSystem"]),
    ],
    targets: [
        .target(
            name: "WarrenDesignSystem",
            path: "Sources/WarrenDesignSystem"
        ),
        .testTarget(
            name: "WarrenDesignSystemTests",
            dependencies: ["WarrenDesignSystem"],
            path: "Tests/WarrenDesignSystemTests"
        ),
    ]
)
