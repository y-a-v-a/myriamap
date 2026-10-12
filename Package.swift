// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Myriamap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyriaGeometry", targets: ["MyriaGeometry"]),
        .library(name: "ZoneAtlas", targets: ["ZoneAtlas"]),
    ],
    targets: [
        .target(name: "MyriaGeometry"),
        .target(
            name: "ZoneAtlas",
            dependencies: ["MyriaGeometry"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MyriaGeometryTests", dependencies: ["MyriaGeometry"]),
        .testTarget(name: "ZoneAtlasTests", dependencies: ["ZoneAtlas"]),
    ]
)
