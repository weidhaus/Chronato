// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Chronato",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The iOS app (iOS/Chronato.xcodeproj) links this as a local package.
        .library(name: "ChronatoCore", targets: ["ChronatoCore"]),
    ],
    dependencies: [
        // Self-updating for the macOS app. Linked into the executable only:
        // ChronatoCore stays dependency-free.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Everything that does not need AppKit: Kimai API, AI-agent sessions,
        // the MCP server, report maths. Kept separate so it is testable with
        // `swift test` and shared by the menu-bar app and `Chronato mcp`.
        .target(
            name: "ChronatoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Chronato",
            dependencies: [
                "ChronatoCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChronatoCoreTests",
            dependencies: ["ChronatoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
