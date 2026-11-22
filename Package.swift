// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CedarPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "COpus",
            path: "Sources/COpus",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AudioToolbox")]
        ),
        .target(
            name: "CVorbis",
            path: "Sources/CVorbis",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWavPack",
            path: "Sources/CWavPack",
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_LEGACY"),
                .define("ENABLE_DSD"),
                .define("HAVE___BUILTIN_CLZ"),
                .define("HAVE_FSEEKO")
            ]
        ),
        .executableTarget(
            name: "CedarPlayer",
            dependencies: ["CVorbis", "CWavPack", "COpus"],
            path: "Sources/CedarPlayer"
        ),
        .testTarget(
            name: "CedarPlayerTests",
            dependencies: ["CedarPlayer"],
            path: "Tests/CedarPlayerTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
