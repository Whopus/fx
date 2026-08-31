// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Curatez",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Curatez", targets: ["Curatez"])
    ],
    targets: [
        .executableTarget(
            name: "Curatez",
            path: "Sources/Curatez"
        ),
        .testTarget(
            name: "CuratezTests",
            dependencies: ["Curatez"]
        )
    ]
)
