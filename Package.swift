// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlugSense",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlugSenseKit", targets: ["PlugSenseKit"]),
        .executable(name: "PlugSenseApp", targets: ["PlugSenseApp"]),
        .executable(name: "plugsense", targets: ["plugsense"]),
    ],
    targets: [
        .target(name: "PlugSenseKit", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "PlugSenseApp", dependencies: ["PlugSenseKit"]),
        .executableTarget(name: "plugsense", dependencies: ["PlugSenseKit"]),
        .testTarget(name: "PlugSenseKitTests", dependencies: ["PlugSenseKit"]),
    ]
)
