// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenProtocol",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenProtocol", targets: ["WarrenProtocol"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
    ],
    targets: [
        .target(
            name: "WarrenProtocol",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
            ],
            path: "Sources/WarrenProtocol"
        ),
        .testTarget(
            name: "WarrenProtocolTests",
            dependencies: ["WarrenProtocol"],
            path: "Tests/WarrenProtocolTests"
        ),
    ]
)
