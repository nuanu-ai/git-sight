// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GitSight",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "GitSightCore"),
        .executableTarget(
            name: "GitSight",
            dependencies: [
                "GitSightCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "GitSightTests",
            dependencies: ["GitSightCore"],
            path: "Tests/GitSightTests"
        )
    ]
)
