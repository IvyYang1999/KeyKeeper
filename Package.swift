// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyKeeper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "keykeeper", targets: ["KeyKeeperCLI"]),
        .library(name: "KeyKeeperCore", targets: ["KeyKeeperCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KeyKeeperCore",
            dependencies: []
        ),
        .executableTarget(
            name: "KeyKeeperCLI",
            dependencies: [
                "KeyKeeperCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KeyKeeperCoreTests",
            dependencies: ["KeyKeeperCore"]
        ),
    ]
)
