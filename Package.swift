// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GroveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GroveCore", targets: ["GroveCore"])
    ],
    targets: [
        .target(name: "GroveCore"),
        .testTarget(name: "GroveCoreTests", dependencies: ["GroveCore"]),
    ]
)
