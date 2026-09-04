// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "keykeeper", targets: ["KeyKeeperCLI"]),
        .library(name: "KeyKeeperCore", targets: ["KeyKeeperCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
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
            ],
            plugins: ["GenerateVersionPlugin"]
        ),
        .executableTarget(
            name: "KeyKeeperApp",
            dependencies: [
                "KeyKeeperCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/KeyKeeperApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ],
            plugins: ["GenerateVersionPlugin"]
        ),
        .testTarget(
            name: "KeyKeeperCoreTests",
            dependencies: ["KeyKeeperCore"]
        ),
        .testTarget(
            name: "KeyKeeperCLITests",
            dependencies: ["KeyKeeperCLI"]
        ),
        .testTarget(
            name: "KeyKeeperAppTests",
            dependencies: ["KeyKeeperApp"]
        ),
        .executableTarget(
            name: "VersionGenerator",
            path: "Tools/VersionGenerator"
        ),
        .plugin(
            name: "GenerateVersionPlugin",
            capability: .buildTool(),
            dependencies: ["VersionGenerator"]
        ),
    ]
)
