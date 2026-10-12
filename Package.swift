// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Myriamap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyriaGeometry", targets: ["MyriaGeometry"]),
        .library(name: "ZoneAtlas", targets: ["ZoneAtlas"]),
        .library(name: "Myriamap", targets: ["Myriamap"]),
        .executable(name: "myriamap", targets: ["MyriamapCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MyriaGeometry"),
        .target(
            name: "ZoneAtlas",
            dependencies: ["MyriaGeometry"],
            resources: [.process("Resources")]
        ),
        .target(name: "Myriamap", dependencies: ["MyriaGeometry", "ZoneAtlas"]),
        .executableTarget(
            name: "MyriamapCLI",
            dependencies: ["Myriamap", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "MyriaGeometryTests", dependencies: ["MyriaGeometry"]),
        .testTarget(name: "ZoneAtlasTests", dependencies: ["ZoneAtlas"]),
        .testTarget(name: "MyriamapTests", dependencies: ["Myriamap"]),
    ]
)
