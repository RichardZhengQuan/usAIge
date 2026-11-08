import AppKit
import SwiftUI
import Testing
@testable import UsageHUD

/// The rail draws each ship from a cached snapshot. A hand-built camera
/// projection once made every snapshot empty, so the rail showed no ship at
/// all; without a graphics device the drawn silhouette must still show.
@MainActor
@Test func everyRailShipImageHasVisiblePixels() throws {
    guard #available(macOS 14.0, *) else { return }
    for kind in PaperweightShipKind.allCases {
        let renderer = ImageRenderer(
            content: RailPaperweightShipImage(kind: kind, size: CGSize(width: 18, height: 12))
                .frame(width: 18, height: 12)
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        var visible = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                visible += 1
            }
        }
        #expect(visible > 40, "\(kind) drew \(visible) visible pixels")
    }
}
