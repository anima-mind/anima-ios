// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnimaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AnimaKit", targets: ["AnimaKit"]),
        // Lo único que linkea la extensión de widgets: snapshot, copy, deep
        // links, tema, BreathMark y la cola de botones. Sin GRDB.
        .library(name: "AnimaWidgetCore", targets: ["AnimaWidgetCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "AnimaWidgetCore"),
        .target(
            name: "AnimaKit",
            dependencies: [
                "AnimaWidgetCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "AnimaKitTests", dependencies: ["AnimaKit", "AnimaWidgetCore"])
    ]
)
