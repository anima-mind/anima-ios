// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnimaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AnimaKit", targets: ["AnimaKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "AnimaKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "AnimaKitTests", dependencies: ["AnimaKit"])
    ]
)
