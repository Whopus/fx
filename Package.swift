// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Fx",
    platforms: [.macOS("26.2")],
    products: [
        .executable(name: "Fx", targets: ["Fx"])
    ],
    targets: [
        .executableTarget(
            name: "Fx",
            path: "Sources/Fx"
        ),
        .testTarget(
            name: "FxTests",
            dependencies: ["Fx"]
        )
    ]
)
