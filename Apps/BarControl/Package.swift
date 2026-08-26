// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTouchBarNative",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexTouchBarNative", targets: ["CodexTouchBarNative"])
    ],
    targets: [
        .target(
            name: "PowerTelemetrySupport",
            path: "Sources/PowerTelemetrySupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "CodexTouchBarNative",
            dependencies: ["PowerTelemetrySupport"],
            path: "Sources/CodexTouchBarNative"
        ),
        .testTarget(
            name: "CodexTouchBarNativeTests",
            dependencies: ["CodexTouchBarNative"],
            path: "Tests/CodexTouchBarNativeTests"
        )
    ]
)
