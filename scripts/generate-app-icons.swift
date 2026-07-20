#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let fileManager = FileManager.default
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let sourceURL = repositoryRoot.appendingPathComponent("Design/AppIcon.png")

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fatalError("Could not load \(sourceURL.path)")
}

func renderMacOSPNG(size: Int) throws -> Data {
    var sourceRect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    guard let sourceCGImage = sourceImage.cgImage(
        forProposedRect: &sourceRect,
        context: nil,
        hints: [.interpolation: NSImageInterpolation.high]
    ) else {
        throw NSError(domain: "AppIconGenerator", code: 1)
    }

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AppIconGenerator", code: 2)
    }

    // Older macOS releases display an ICNS file's alpha silhouette directly
    // instead of applying the modern rounded app-icon mask. Precompose the
    // macOS shape so the Dock never falls back to a full opaque square.
    let scale = CGFloat(size) / 1024
    let iconRect = CGRect(
        x: 100 * scale,
        y: 100 * scale,
        width: 824 * scale,
        height: 824 * scale
    )
    let iconPath = CGPath(
        roundedRect: iconRect,
        cornerWidth: 185 * scale,
        cornerHeight: 185 * scale,
        transform: nil
    )

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.addPath(iconPath)
    context.clip()
    context.interpolationQuality = .high
    context.draw(sourceCGImage, in: iconRect)

    guard let renderedImage = context.makeImage() else {
        throw NSError(domain: "AppIconGenerator", code: 3)
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "AppIconGenerator", code: 4)
    }
    CGImageDestinationAddImage(destination, renderedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AppIconGenerator", code: 5)
    }
    return output as Data
}

let masterPNG = try Data(contentsOf: sourceURL)
let masterDestinations = [
    "iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "site/public/app-icon.png",
]

for path in masterDestinations {
    try masterPNG.write(to: repositoryRoot.appendingPathComponent(path), options: .atomic)
}

try renderMacOSPNG(size: 1024).write(
    to: repositoryRoot.appendingPathComponent("Sources/UsageHUD/Resources/AppIcon.png"),
    options: .atomic
)

let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("usAIge-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

let iconsetFiles = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, size) in iconsetFiles {
    try renderMacOSPNG(size: size).write(
        to: iconsetURL.appendingPathComponent(filename),
        options: .atomic
    )
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconsetURL.path,
    "-o", repositoryRoot.appendingPathComponent("Sources/UsageHUD/Resources/AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "AppIconGenerator", code: Int(iconutil.terminationStatus))
}

print("Generated legacy-safe macOS, iOS, and website icons from Design/AppIcon.png")
