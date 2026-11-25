// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotifyNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SpotifyNotch", targets: ["SpotifyNotch"])
    ],
    targets: [
        .executableTarget(
            name: "SpotifyNotch",
            path: "Sources/SpotifyNotch",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
