// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CatHerder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CatHerder",
            path: "Sources/CatHerder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatHerderTests",
            dependencies: ["CatHerder"],
            path: "Tests/CatHerderTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
