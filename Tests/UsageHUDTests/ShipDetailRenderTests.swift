import AppKit
import Metal
import SceneKit
import Testing
@testable import UsageHUD

private let shipDetailDirectory = ProcessInfo.processInfo.environment["USAIGE_RENDER_SHIPS"]

/// The decorated models still share one physical envelope and one projected
/// waterline. Artwork is inspected at its sailing size and both rail sizes.
@Suite("ShipDetails", .serialized)
@MainActor
struct ShipDetailRenderTests {
    @Test func detailedModelsStayInsideTheUnsinkableClearance() throws {
        guard #available(macOS 14.0, *) else { return }
        let margin = PaperweightConstants.boatMargin * PaperweightConstants.unitsPerPixel
        let height = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel
        let draft = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel
        let halfDepth = PaperweightConstants.ZF
        for kind in PaperweightShipKind.allCases {
            let ship = PaperweightShipFactory.make(kind)
            var corners: [SCNVector3] = []
            ship.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                let bounds = geometry.boundingBox
                for x in [bounds.min.x, bounds.max.x] {
                    for y in [bounds.min.y, bounds.max.y] {
                        for z in [bounds.min.z, bounds.max.z] {
                            corners.append(node.convertPosition(SCNVector3(x, y, z), to: nil))
                        }
                    }
                }
            }
            try #require(!corners.isEmpty, "\(kind.title) has no model geometry")
            #expect(corners.allSatisfy { abs(Double($0.x)) <= margin + 0.0001 },
                    "\(kind.title) exceeds the reserved bow/stern clearance")
            #expect(corners.allSatisfy { Double($0.y) <= height + 0.0001 },
                    "\(kind.title) exceeds the tallest reserved mast")
            #expect(corners.allSatisfy { Double($0.y) >= -draft - 0.0001 },
                    "\(kind.title) exceeds the reserved keel depth")
            #expect(corners.allSatisfy { abs(Double($0.z)) <= halfDepth + 0.0001 },
                    "\(kind.title) exceeds the paperweight's interior depth")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func detailedSnapshotsRemainVisibleAndUnclippedAtEveryDisplaySize() throws {
        guard #available(macOS 14.0, *) else { return }
        for kind in PaperweightShipKind.allCases {
            for size in [CGSize(width: 360, height: 240), CGSize(width: 42, height: 28), CGSize(width: 18, height: 12)] {
                let image = try snapshot(kind, size: size)
                let pixels = try alphaBounds(image)
                #expect(pixels.count > max(12, image.width * image.height / 400),
                        "\(kind.title) disappeared at \(size)")
                if size.width >= 300 {
                    #expect(pixels.minX > 0 && pixels.maxX < image.width - 1
                            && pixels.minY > 0 && pixels.maxY < image.height - 1,
                            "\(kind.title) is clipped by its fixed sailing snapshot")
                }
            }
        }
    }

    /// USAIGE_RENDER_SHIPS=/path swift test --filter ShipDetailRenderTests
    @Test(.enabled(if: shipDetailDirectory != nil && MTLCreateSystemDefaultDevice() != nil))
    func exportsAllDetailedShipsForVisualReview() throws {
        guard #available(macOS 14.0, *) else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(shipDetailDirectory))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in PaperweightShipKind.allCases {
            for size in [CGSize(width: 360, height: 240), CGSize(width: 42, height: 28), CGSize(width: 18, height: 12)] {
                let image = try snapshot(kind, size: size)
                try writePNG(image, to: directory.appendingPathComponent(
                    "ship-detail-\(kind.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
                ))
            }
        }
        for dark in [false, true] {
            for collection in PaperweightShipCollection.allCases {
                let name = collection == .classics ? "ship-details" : "ship-details-\(collection.rawValue)"
                try writePNG(contactSheet(kinds: collection.ships, dark: dark), to: directory.appendingPathComponent(
                    "\(name)-\(dark ? "dark" : "light").png"
                ))
            }
        }
    }

    @available(macOS 14.0, *)
    private func snapshot(_ kind: PaperweightShipKind, size: CGSize) throws -> CGImage {
        let image = try #require(PaperweightShipImageCache.shared.image(for: kind, size: size, scale: 2))
        var rect = CGRect(origin: .zero, size: size)
        return try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    private func alphaBounds(_ image: CGImage) throws -> (count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0, minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * context.bytesPerRow + x * 4 + 3] > 25 {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return (count, minX, maxX, minY, maxY)
    }

    @available(macOS 14.0, *)
    private func contactSheet(kinds: [PaperweightShipKind], dark: Bool) throws -> CGImage {
        let rows = max(1, (kinds.count + 2) / 3)
        let width = 1_200, height = rows * 300
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let background = dark ? NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.18, alpha: 1)
            : NSColor(calibratedRed: 0.87, green: 0.94, blue: 0.96, alpha: 1)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, kind) in kinds.enumerated() {
            let x = CGFloat(index % 3) * 400, y = CGFloat(rows - 1 - index / 3) * 300
            let frame = CGRect(x: x + 20, y: y + 20, width: 360, height: 240)
            let waterline = frame.minY + frame.height * (1 - RailPaperweightShipImage.waterlineFraction)
            context.setStrokeColor((dark ? NSColor.white : NSColor.systemTeal).withAlphaComponent(0.22).cgColor)
            context.setLineWidth(0.8)
            context.move(to: CGPoint(x: x + 12, y: waterline))
            context.addLine(to: CGPoint(x: x + 388, y: waterline))
            context.strokePath()
            context.draw(try snapshot(kind, size: frame.size), in: frame)
            (kind.title as NSString).draw(at: CGPoint(x: x + 20, y: y + 272), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: dark ? NSColor.white : NSColor(calibratedWhite: 0.15, alpha: 1),
            ])
            for (miniSize, offset) in [(CGSize(width: 42, height: 28), 300.0),
                                       (CGSize(width: 18, height: 12), 356.0)] {
                context.draw(try snapshot(kind, size: miniSize), in: CGRect(
                    x: x + CGFloat(offset), y: y + 2, width: miniSize.width, height: miniSize.height
                ))
            }
        }
        return try #require(context.makeImage())
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
