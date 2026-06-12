// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CustomMacDock",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CustomMacDock",
            path: "Sources/CustomMacDock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
