// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnimaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnimaKit", targets: ["AnimaKit"])
    ],
    targets: [
        .target(name: "AnimaKit"),
        .testTarget(name: "AnimaKitTests", dependencies: ["AnimaKit"])
    ]
)
