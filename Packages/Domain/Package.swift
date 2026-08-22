// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenDomain",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WarrenDomain", targets: ["WarrenDomain"]),
    ],
    targets: [
        .target(
            name: "WarrenDomain",
            path: "Sources/WarrenDomain"
        ),
        .testTarget(
            name: "WarrenDomainTests",
            dependencies: ["WarrenDomain"],
            path: "Tests/WarrenDomainTests"
        ),
    ]
)
