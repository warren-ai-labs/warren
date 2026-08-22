// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Warren",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "Packages/Desktop"),
        .package(path: "Packages/GhosttyAdapter"),
        .package(path: "Packages/StateStore"),
        .package(path: "Packages/Domain"),
        .package(path: "Packages/ClientCore"),
        .package(path: "Packages/Transport"),
        .package(path: "Packages/Observation"),
        .package(path: "Packages/DesignSystem"),
    ],
    targets: [
        .executableTarget(
            name: "Warren",
            dependencies: [
                .product(name: "WarrenDesktop", package: "Desktop"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
                .product(name: "WarrenStateStore", package: "StateStore"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenClientCore", package: "ClientCore"),
                .product(name: "WarrenTransport", package: "Transport"),
                .product(name: "WarrenDesignSystem", package: "DesignSystem"),
            ],
            path: "Sources/Warren"
        ),
        .executableTarget(
            name: "WarrenDaemonMenuBar",
            path: "Sources/WarrenDaemonMenuBar"
        ),
        .executableTarget(
            name: "UIProbe",
            dependencies: [
                .product(name: "WarrenDesktop", package: "Desktop"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenObservation", package: "Observation"),
            ],
            path: "Sources/UIProbe"
        ),
        .executableTarget(
            name: "TerminalProbe",
            dependencies: [
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "GhosttyAdapter", package: "GhosttyAdapter"),
            ],
            path: "Sources/TerminalProbe"
        ),
        .testTarget(
            name: "WarrenTests",
            dependencies: [
                "Warren",
                .product(name: "WarrenDomain", package: "Domain"),
            ],
            path: "Tests/WarrenTests"
        ),
    ]
)
