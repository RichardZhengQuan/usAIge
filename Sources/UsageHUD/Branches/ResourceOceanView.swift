import AppKit
import SwiftUI

/// The resource's layers are the water beneath the cruising ship. The native
/// atmosphere keeps ownership of weather, buoyancy and its visibility clock.
@available(macOS 14.0, *)
struct ResourceOceanView: NSViewRepresentable {
    let configuration: PaperweightConfiguration
    let selectedLayerID: String
    var weather: CruiseWeather
    var ship: PaperweightShipKind
    var isActive = true
    var command: PaperweightSceneCommand? = nil
    var onSelect: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.usageSceneFrozen) private var frozen

    func makeNSView(context: Context) -> UsageAtmosphereView {
        let view = UsageAtmosphereView()
        configure(view)
        return view
    }

    func updateNSView(_ view: UsageAtmosphereView, context: Context) { configure(view) }

    static func dismantleNSView(_ view: UsageAtmosphereView, coordinator: ()) { view.stop() }

    private func configure(_ view: UsageAtmosphereView) {
        view.configureOcean(configuration: configuration, selectedLayerID: selectedLayerID, onSelect: onSelect)
        view.configure(active: isActive, compact: false, weather: weather, ship: ship, showsShip: true,
                       dark: colorScheme == .dark, reduced: reduceMotion || frozen, capturesWeather: frozen,
                       command: command)
    }
}

/// Capacity-preserving depth geometry, shared by drawing and pointer selection.
/// Small categories remain small; readable labels never inflate their bytes.
struct ResourceOceanLayout {
    struct Band: Equatable {
        let layer: PaperweightLayer
        let start: Double
        let end: Double
    }

    let bands: [Band]

    init(configuration: PaperweightConfiguration) {
        guard configuration.capacityBytes > 0, configuration.freeBytes != nil else {
            bands = [Band(layer: configuration.freeLayer, start: 0, end: 1)]
            return
        }
        var layers = Array(configuration.layers.reversed())
        var remainder = configuration.freeLayer
        let used = layers.reduce(0.0) { $0 + Double(max(0, $1.bytes)) }
        remainder.bytes = max(remainder.bytes, configuration.capacityBytes - min(configuration.capacityBytes, configuration.usedBytes))
        layers.append(remainder)
        let total = max(Double(configuration.capacityBytes), used + Double(max(0, remainder.bytes)))
        var level = 0.0
        var laidOut = layers.compactMap { layer -> Band? in
            guard layer.bytes > 0 else { return nil }
            let start = level
            level = min(1, level + Double(layer.bytes) / total)
            return Band(layer: layer, start: start, end: level)
        }
        // Repeated floating-point additions can finish just below one. The
        // final band owns the bottom edge for both painting and hit testing.
        if let last = laidOut.last {
            laidOut[laidOut.count - 1] = Band(layer: last.layer, start: last.start, end: 1)
        }
        bands = laidOut
    }

    static func boundary(at fraction: Double, surface: Double, bottom: Double) -> Double {
        surface + min(1, max(0, fraction)) * max(0, bottom - surface)
    }

    func layer(at point: CGPoint, size: CGSize, surface: Double) -> PaperweightLayer? {
        guard point.x >= 0, point.x <= size.width, point.y >= surface, point.y <= size.height,
              size.height > surface else { return nil }
        let depth = (point.y - surface) / (size.height - surface)
        return bands.first { depth >= $0.start && (depth < $0.end || $0.end == 1) }?.layer
    }
}

/// Text follows each band's actual depth. Adjacent thin bands use different
/// horizontal positions instead of gaining fictitious height or callout boxes.
struct ResourceOceanLabelLayout {
    struct Placement {
        let layerID: String
        let frame: CGRect
        let anchor: CGPoint
    }

    let placements: [Placement]

    init(ocean: ResourceOceanLayout, size: CGSize, textSizes: [String: CGSize],
         selectedLayerID: String = "", surface: (Double) -> Double) {
        guard size.width.isFinite, size.height.isFinite, size.width > 48, size.height > 24 else {
            placements = []
            return
        }
        let inset = 24.0, gap = 8.0
        let canvasWidth = Double(size.width), canvasHeight = Double(size.height)
        var result: [Placement] = []
        let ordered = ocean.bands.sorted {
            if ($0.layer.id == selectedLayerID) != ($1.layer.id == selectedLayerID) {
                return $0.layer.id == selectedLayerID
            }
            return $0.start < $1.start
        }
        for band in ordered {
            guard let measured = textSizes[band.layer.id], measured.width.isFinite, measured.height.isFinite,
                  measured.width > 0, measured.height > 0 else { continue }
            let width = min(ceil(Double(measured.width)), canvasWidth - inset * 2)
            let height = ceil(Double(measured.height))
            let lastX = canvasWidth - inset - width
            var columns = [inset]
            // Fill the next open column first; this keeps clustered thin
            // labels in a readable left-to-right sequence at a common depth.
            columns += result.map { Double($0.frame.maxX) + gap }
            columns += [lastX, (inset + lastX) * 0.5]
            columns += result.map { Double($0.frame.minX) - gap - width }
            columns += (1..<8).map { inset + (lastX - inset) * Double($0) / 8 }
            var placed: Placement?
            for x in columns where x >= inset && x <= lastX {
                let centerX = x + width * 0.5
                let wave = surface(centerX)
                guard wave.isFinite else { continue }
                let tops = (0...12).map { surface(x + width * Double($0) / 12) }
                guard tops.allSatisfy(\.isFinite), let highestWater = tops.max() else { continue }
                let minimumY = max(4, highestWater + 4)
                let maximumY = canvasHeight - 6 - height
                guard maximumY >= minimumY else { continue }
                // Thick bands can choose another position inside their own
                // depth if a neighboring label needs the middle position.
                for portion in [0.5, 0.25, 0.75] {
                    let depth = band.start + (band.end - band.start) * portion
                    let anchor = CGPoint(x: centerX, y: ResourceOceanLayout.boundary(at: depth, surface: wave, bottom: canvasHeight))
                    let y = min(maximumY, max(minimumY, Double(anchor.y) - height * 0.5))
                    let frame = CGRect(x: x, y: y, width: width, height: height)
                    guard !result.contains(where: { $0.frame.insetBy(dx: -4, dy: -2).intersects(frame) }) else { continue }
                    placed = Placement(layerID: band.layer.id, frame: frame, anchor: anchor)
                    break
                }
                if placed != nil { break }
            }
            // A physically crowded narrow preview keeps its native legend;
            // positive byte counts are never discarded by a thickness cutoff.
            if let placed { result.append(placed) }
        }
        placements = result
    }
}
