// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mirador",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "mirador", targets: ["Mirador"])
    ],
    targets: [
        .executableTarget(
            name: "Mirador",
            path: "Sources/Mirador"
        ),
        .testTarget(
            name: "MiradorTests",
            dependencies: ["Mirador"],
            path: "Tests/MiradorTests"
        )
    ]
)
