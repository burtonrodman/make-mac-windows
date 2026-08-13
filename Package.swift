// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PCMode",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PCMode",
            path: "Sources/PCMode"
        )
    ]
)
