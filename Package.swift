// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileScannerApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FileScannerApp",
            path: "Sources"
        )
    ]
)
