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
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "CodexTouchBarNative",
            dependencies: ["PowerTelemetrySupport"],
            path: "Sources/CodexTouchBarNative",
            resources: [.copy("Resources/MagpieIcons")]
        ),
        .executableTarget(
            name: "BarControlPowerHelper",
            dependencies: ["PowerTelemetrySupport"],
            path: "Sources/BarControlPowerHelper"
        ),
        .testTarget(
            name: "CodexTouchBarNativeTests",
            dependencies: ["CodexTouchBarNative"],
            path: "Tests/CodexTouchBarNativeTests"
        )
    ]
)
