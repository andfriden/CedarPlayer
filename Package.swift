// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CedarPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CedarPlayer",
            path: "Sources/CedarPlayer"
        )
    ]
)
