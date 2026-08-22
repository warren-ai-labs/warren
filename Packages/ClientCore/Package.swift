// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenClientCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenClientCore", targets: ["WarrenClientCore"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
    ],
    targets: [
        .target(
            name: "WarrenClientCore",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
            ],
            path: "Sources/WarrenClientCore"
        ),
        .testTarget(
            name: "WarrenClientCoreTests",
            dependencies: ["WarrenClientCore"],
            path: "Tests/WarrenClientCoreTests"
        ),
    ]
)
