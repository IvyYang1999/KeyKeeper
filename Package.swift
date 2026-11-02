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
        // Shared test doubles that behave like the real Keychain. Not a product: nothing ships it.
        .target(
            name: "KeyKeeperTestSupport",
            dependencies: ["KeyKeeperCore"],
            path: "Tests/KeyKeeperTestSupport"
        ),
        .testTarget(
            name: "KeyKeeperCoreTests",
            dependencies: ["KeyKeeperCore", "KeyKeeperTestSupport"]
        ),
        .testTarget(
            name: "KeyKeeperCLITests",
            dependencies: ["KeyKeeperCLI", "KeyKeeperTestSupport"]
        ),
        .testTarget(
            name: "KeyKeeperAppTests",
            dependencies: ["KeyKeeperApp", "KeyKeeperTestSupport"],
            exclude: ["Fixtures"]
        ),
        .executableTarget(
            name: "VersionGenerator",
            path: "Tools/VersionGenerator"
        ),
        // Included only by the opt-in identity-migration packaging script.
        .executableTarget(
            name: "KeyKeeperMigrationProbe",
            dependencies: ["KeyKeeperCore"],
            path: "Tools/KeyKeeperMigrationProbe"
        ),
        .executableTarget(
            name: "KeyKeeperMigrationBridge",
            dependencies: ["KeyKeeperCore"],
            path: "Tools/KeyKeeperMigrationBridge"
        ),
        // Isolated synthetic probes; never bundled into the shipping application.
        .executableTarget(
            name: "KeyKeeperSyncAcceptance",
            dependencies: ["KeyKeeperCore"],
            path: "Tools/KeyKeeperSyncAcceptance"
        ),
        .executableTarget(
            name: "KeyKeeperIdentityProbe",
            dependencies: ["KeyKeeperCore"],
            path: "Tools/KeyKeeperIdentityProbe"
        ),
        .executableTarget(
            name: "KeyKeeperCloudProbe",
            dependencies: ["KeyKeeperCore"],
            path: "Tools/KeyKeeperCloudProbe",
            exclude: ["README.md"]
        ),
        .plugin(
            name: "GenerateVersionPlugin",
            capability: .buildTool(),
            dependencies: ["VersionGenerator"]
        ),
    ]
)
