// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GitSight",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "GitSightCore"),
        .executableTarget(
            name: "GitSight",
            dependencies: ["GitSightCore"]
        ),
        .executableTarget(
            name: "GitSightTests",
            dependencies: ["GitSightCore"],
            path: "Tests/GitSightTests"
        )
    ]
)
