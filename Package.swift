// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClippyCore", targets: ["ClippyCore"]),
        .library(name: "ClippyEngine", targets: ["ClippyEngine"]),
    ],
    targets: [
        .target(
            name: "ClippyCore",
            path: "Sources/Core"
        ),
        .target(
            name: "ClippyEngine",
            dependencies: ["ClippyCore"],
            path: "Sources/Engine"
        ),
        .executableTarget(
            name: "Clippy",
            dependencies: ["ClippyCore", "ClippyEngine"],
            path: "Sources",
            exclude: [
                "Core",
                "Engine"
            ]
        ),
        .testTarget(
            name: "ClippyTests",
            dependencies: ["ClippyCore", "ClippyEngine", "Clippy"],
            path: "Tests/ClippyTests"
        )
    ]
)
