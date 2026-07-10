// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageHUD",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "UsageHUD", targets: ["UsageHUD"]),
    ],
    targets: [
        .executableTarget(name: "UsageHUD"),
        .testTarget(name: "UsageHUDTests", dependencies: ["UsageHUD"]),
    ]
)
