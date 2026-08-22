// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenDesktop",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "WarrenDesktop", targets: ["WarrenDesktop"]),
    ],
    dependencies: [
        .package(path: "../Domain"),
        .package(path: "../ClientCore"),
        .package(path: "../DesignSystem"),
        .package(path: "../Observation"),
    ],
    targets: [
        .target(
            name: "WarrenDesktop",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenDesignSystem", package: "DesignSystem"),
                .product(name: "WarrenObservation", package: "Observation"),
            ],
            path: "Sources/WarrenDesktop",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "WarrenDesktopTests",
            dependencies: [
                "WarrenDesktop",
                .product(name: "WarrenDesignSystem", package: "DesignSystem"),
            ],
            path: "Tests/WarrenDesktopTests"
        ),
    ]
)
