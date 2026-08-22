// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenStateStore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenStateStore", targets: ["WarrenStateStore"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../ClientCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
    ],
    targets: [
        .target(
            name: "WarrenStateStore",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/WarrenStateStore"
        ),
        .testTarget(
            name: "WarrenStateStoreTests",
            dependencies: [
                "WarrenStateStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/WarrenStateStoreTests"
        ),
    ]
)
