// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiquidGlassTaskbar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LiquidGlassTaskbar",
            path: "Sources/LiquidGlassTaskbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
