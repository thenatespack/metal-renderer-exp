// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalRenderer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MetalRenderer",
            path: "Sources/MetalRenderer"
        )
    ]
)
