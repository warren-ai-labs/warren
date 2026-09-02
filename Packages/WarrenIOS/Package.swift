// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenIOS",
    platforms: [
        .iOS(.v17),
        // Keeping a macOS destination makes previews and package tests
        // possible on a developer Mac; the production target is iOS 17.
        .macOS(.v14),
    ],
    products: [
        .library(name: "WarrenIOS", targets: ["WarrenIOS"]),
        .executable(name: "WarrenIOSApp", targets: ["WarrenIOSApp"]),
    ],
    dependencies: [
        .package(path: "../DesignSystem"),
        .package(path: "../Domain"),
        .package(path: "../Transport"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "WarrenIOS",
            dependencies: [
                .product(name: "WarrenDesignSystem", package: "DesignSystem"),
                .product(name: "WarrenDomain", package: "Domain"),
                .product(name: "WarrenTransport", package: "Transport"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/WarrenIOS",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "WarrenIOSApp",
            dependencies: ["WarrenIOS"],
            path: "Sources/WarrenIOSApp",
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "WarrenIOSTests",
            dependencies: ["WarrenIOS"],
            path: "Tests/WarrenIOSTests"
        ),
    ]
)
