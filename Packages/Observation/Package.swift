// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WarrenObservation",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "WarrenObservation", targets: ["WarrenObservation"]),
    ],
    targets: [
        .target(
            name: "WarrenObservation",
            path: "Sources/WarrenObservation"
        ),
        .testTarget(
            name: "WarrenObservationTests",
            dependencies: ["WarrenObservation"],
            path: "Tests/WarrenObservationTests"
        ),
    ]
)
