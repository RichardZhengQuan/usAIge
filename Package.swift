// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "usAIge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "usAIge", targets: ["UsageHUD"]),
    ],
    targets: [
        .executableTarget(
            name: "UsageHUD",
            exclude: [
                "Resources",
                "Views/HUDView 2.swift",
                "Views/HUDView 3.swift",
                "Views/QuotaRowView 2.swift",
            ]
        ),
        .testTarget(name: "UsageHUDTests", dependencies: ["UsageHUD"]),
    ]
)
