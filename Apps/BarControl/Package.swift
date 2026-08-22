// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTouchBarNative",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexTouchBarNative", targets: ["CodexTouchBarNative"])
    ],
    targets: [
        .executableTarget(
            name: "CodexTouchBarNative",
            path: "Sources/CodexTouchBarNative"
        )
    ]
)
