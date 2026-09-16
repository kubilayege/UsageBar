// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageBar",
            path: "Sources/UsageBar",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
