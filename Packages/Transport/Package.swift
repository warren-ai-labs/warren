// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenTransport",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenTransport", targets: ["WarrenTransport"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../Protocol"),
        .package(path: "../ClientCore"),
        .package(url: "https://github.com/abcdlsj/bolthole", branch: "main"),
    ],
    targets: [
        .target(
            name: "WarrenTransport",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenProtocol", package: "Protocol"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "Bolthole", package: "bolthole"),
            ],
            path: "Sources/WarrenTransport"
        ),
        .testTarget(
            name: "WarrenTransportTests",
            dependencies: ["WarrenTransport"],
            path: "Tests/WarrenTransportTests"
        ),
    ]
)
