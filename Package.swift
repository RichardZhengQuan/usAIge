// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "usAIge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "usAIge", targets: ["UsageHUD"]),
    ],
    targets: [
        .executableTarget(name: "UsageHUD", exclude: ["Resources"]),
        .testTarget(name: "UsageHUDTests", dependencies: ["UsageHUD"]),
    ]
)
