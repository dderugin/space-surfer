// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceSurf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceSurf", targets: ["SpaceSurf"]),
        .executable(name: "SpaceSurfBench", targets: ["SpaceSurfBench"]),
    ],
    targets: [
        .target(name: "DiskWalker"),
        .target(name: "ScanCore", dependencies: ["DiskWalker"]),
        .executableTarget(name: "SpaceSurf", dependencies: ["ScanCore"]),
        .executableTarget(name: "SpaceSurfBench", dependencies: ["ScanCore"]),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
        .testTarget(name: "SpaceSurfTests", dependencies: ["SpaceSurf", "ScanCore"]),
    ]
)
