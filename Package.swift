// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "usAIge",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "usAIge", targets: ["UsageHUD"]),
    ],
    targets: [
        .target(
            name: "CZstd",
            exclude: ["vendor", "LICENSE.txt", "PROVENANCE.md"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "UsageHUD",
            dependencies: ["CZstd"],
            exclude: ["Resources"]
        ),
        .testTarget(name: "UsageHUDTests", dependencies: ["UsageHUD"]),
    ]
)
