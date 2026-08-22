// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenTerminalRenderer",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenTerminalRenderer", targets: ["WarrenTerminalRenderer"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../ClientCore"),
    ],
    targets: [
        .target(
            name: "WarrenTerminalRenderer",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
            ],
            path: "Sources/WarrenTerminalRenderer"
        ),
        .testTarget(
            name: "WarrenTerminalRendererTests",
            dependencies: ["WarrenTerminalRenderer"],
            path: "Tests/WarrenTerminalRendererTests"
        ),
    ]
)
