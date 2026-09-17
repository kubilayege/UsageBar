// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "UsageBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/UsageBar",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
