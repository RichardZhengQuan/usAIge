import AppKit
import Testing
@testable import UsageHUD

@Suite("Resource ocean labels")
struct ResourceOceanLabelTests {
    @Test @MainActor func allStorageAndMemoryCategoriesStayInTheWaterAtMinimumWindowWidth() {
        let cases: [[String]] = [
            ["Worktrees", "Build cache", "Tool storage", "macOS and apps"],
            ["Codex", "Claude", "Gemini", "Cursor", "Grok", "Dev servers"]
        ]
        for names in cases {
            let ocean = ResourceOceanLayout(configuration: fixture(names: names))
            let sizes = textSizes(ocean)
            for size in [CGSize(width: 900, height: 240), CGSize(width: 1180, height: 360)] {
                let layout = ResourceOceanLabelLayout(ocean: ocean, size: size, textSizes: sizes,
                                                      surface: { _ in Double(size.height) * 0.61 })
                #expect(Set(layout.placements.map(\.layerID)) == Set(ocean.bands.map(\.layer.id)))
                assertValid(layout, ocean: ocean, size: size, surface: { _ in Double(size.height) * 0.61 })
            }
        }
    }

    @Test @MainActor func adjacentTinyBandsSpreadHorizontallyWithoutChangingTheirDepth() {
        let ocean = ResourceOceanLayout(configuration: fixture(names: ["Codex", "Claude", "Cursor"], thin: true))
        let size = CGSize(width: 900, height: 240)
        let layout = ResourceOceanLabelLayout(ocean: ocean, size: size, textSizes: textSizes(ocean),
                                              surface: { _ in 146.4 })
        #expect(layout.placements.count == ocean.bands.count)
        let thinIDs = Set(ocean.bands.filter { $0.layer.id != "free" }.map(\.layer.id))
        let thin = layout.placements.filter { thinIDs.contains($0.layerID) }
        #expect(Set(thin.map { $0.frame.minX }).count == thin.count)
        #expect(thin.allSatisfy { $0.anchor.y >= 146.4 && $0.anchor.y < 146.5 })
        assertValid(layout, ocean: ocean, size: size, surface: { _ in 146.4 })
    }

    @Test @MainActor func narrowWavyAndUnknownScenesKeepLabelsInsideTheWaterAndFrame() {
        let size = CGSize(width: 420, height: 240)
        let wave: (Double) -> Double = { 149 + sin($0 / 33) * 8 }
        let ocean = ResourceOceanLayout(configuration: fixture(names: ["Codex", "Claude", "Cursor"], thin: true))
        let layout = ResourceOceanLabelLayout(ocean: ocean, size: size, textSizes: textSizes(ocean),
                                              selectedLayerID: "layer-0", surface: wave)
        #expect(layout.placements.contains { $0.layerID == "layer-0" })
        assertValid(layout, ocean: ocean, size: size, surface: wave)

        var unknown = fixture(names: ["Codex"])
        unknown.freeBytes = nil
        let unread = ResourceOceanLayout(configuration: unknown)
        let unreadLabels = ResourceOceanLabelLayout(ocean: unread, size: size, textSizes: textSizes(unread), surface: wave)
        #expect(unreadLabels.placements.count == 1)
        #expect(unreadLabels.placements.first?.layerID == unknown.freeLayer.id)
        assertValid(unreadLabels, ocean: unread, size: size, surface: wave)
    }

    @Test func impossibleAndInvalidFramesDoNotCreateClippedOrOverlappingText() {
        let ocean = ResourceOceanLayout(configuration: fixture(names: ["Codex"]))
        let sizes = Dictionary(uniqueKeysWithValues: ocean.bands.map { ($0.layer.id, CGSize(width: 100, height: 16)) })
        for size in [CGSize.zero, CGSize(width: 20, height: 240), CGSize(width: 420, height: 20)] {
            #expect(ResourceOceanLabelLayout(ocean: ocean, size: size, textSizes: sizes, surface: { _ in 10 }).placements.isEmpty)
        }
        #expect(ResourceOceanLabelLayout(ocean: ocean, size: CGSize(width: 420, height: 240),
                                        textSizes: sizes, surface: { _ in .nan }).placements.isEmpty)
    }

    @MainActor private func textSizes(_ ocean: ResourceOceanLayout) -> [String: CGSize] {
        Dictionary(uniqueKeysWithValues: ocean.bands.map { band in
            let amount = band.layer.isMeasuring ? "Measuring…" : BoardText.bytes(band.layer.bytes)
            let text = NSAttributedString(string: "\(band.layer.title) · \(amount)",
                                          attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            return (band.layer.id, text.size())
        })
    }

    private func fixture(names: [String], thin: Bool = false) -> PaperweightConfiguration {
        let amounts: [Int64] = names.indices.map { thin ? 1 : Int64(($0 + 1) * 250_000_000) }
        let capacity: Int64 = 24_000_000_000
        return PaperweightConfiguration(id: .storage, capacityBytes: capacity,
            layers: names.enumerated().map { index, name in
                PaperweightLayer(id: "layer-\(index)", title: name, bytes: amounts[index], colorHex: 0, inkHex: 0)
            }, freeBytes: capacity - amounts.reduce(0, +))
    }

    private func assertValid(_ layout: ResourceOceanLabelLayout, ocean: ResourceOceanLayout,
                             size: CGSize, surface: (Double) -> Double) {
        let frame = CGRect(origin: .zero, size: size)
        for placement in layout.placements {
            #expect(frame.contains(placement.frame))
            for portion in 0...12 {
                let x = Double(placement.frame.minX) + Double(placement.frame.width) * Double(portion) / 12
                #expect(Double(placement.frame.minY) >= surface(x))
            }
            if let band = ocean.bands.first(where: { $0.layer.id == placement.layerID }) {
                let depth = (Double(placement.anchor.y) - surface(Double(placement.anchor.x)))
                    / (Double(size.height) - surface(Double(placement.anchor.x)))
                #expect(depth >= band.start - 0.000_001 && depth <= band.end + 0.000_001)
            }
        }
        for (index, placement) in layout.placements.enumerated() {
            for other in layout.placements.dropFirst(index + 1) {
                #expect(!placement.frame.intersects(other.frame))
            }
        }
    }
}
