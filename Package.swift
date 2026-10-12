// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Myriamap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyriaGeometry", targets: ["MyriaGeometry"]),
    ],
    targets: [
        .target(name: "MyriaGeometry"),
        .testTarget(name: "MyriaGeometryTests", dependencies: ["MyriaGeometry"]),
    ]
)
