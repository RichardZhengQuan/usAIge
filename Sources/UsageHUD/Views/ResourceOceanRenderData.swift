import Foundation

/// A small immutable GPU payload sampled from the same water surface used by
/// buoyancy and hit testing. It contains pigment, never painted screen bands.
struct ResourceOceanRenderData: Sendable {
    static let maximumLayerCount = 16
    static let surfaceSampleCount = 65

    /// RGB pigment plus its cumulative end depth, from the surface downward.
    let layers: [SIMD4<Float>]
    /// Physical waterline normalized to the scene height, sampled left to right.
    let surface: [Float]

    init(configuration: PaperweightConfiguration, size: CGSize, surface sample: (Double) -> Double) {
        let bands = ResourceOceanLayout(configuration: configuration).bands
        var pigments = bands.map { band in
            let hex = Self.pigmentHex(for: band.layer)
            return SIMD4(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255,
                         Float(hex & 255) / 255, Float(band.end))
        }
        if pigments.count > Self.maximumLayerCount {
            // Keep all bytes represented if a future plugin adds more tools:
            // the final pigment is the capacity-weighted tail, not a cutoff.
            let firstTail = Self.maximumLayerCount - 1
            let start = firstTail > 0 ? pigments[firstTail - 1].w : 0
            var previous = start, weight: Float = 0
            var combined = SIMD3<Float>.zero
            for pigment in pigments.dropFirst(firstTail) {
                let thickness = max(0, pigment.w - previous)
                combined += SIMD3(pigment.x, pigment.y, pigment.z) * thickness
                weight += thickness
                previous = pigment.w
            }
            combined /= max(0.000_001, weight)
            pigments = Array(pigments.prefix(firstTail)) + [SIMD4(combined.x, combined.y, combined.z, 1)]
        }
        layers = pigments
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite && size.height > 0 ? size.height : 1
        surface = (0..<Self.surfaceSampleCount).map { index in
            let x = width * Double(index) / Double(Self.surfaceSampleCount - 1)
            let value = sample(x) / height
            return Float(value.isFinite ? min(0.98, max(0.02, value)) : 0.61)
        }
    }

    static func pigmentHex(for layer: PaperweightLayer) -> UInt32 {
        switch layer.id {
        case "mfree": 0x63A6BC
        case "free": 0x7CC2C6
        case "other": 0x447F9C
        default: layer.colorHex
        }
    }

    /// Matches the shader's linear sampling of the physical surface.
    func surfaceFraction(at x: Double) -> Double {
        let position = min(1, max(0, x.isFinite ? x : 0)) * Double(surface.count - 1)
        let first = min(surface.count - 1, Int(position))
        let next = min(surface.count - 1, first + 1)
        return Double(surface[first]) + (Double(surface[next]) - Double(surface[first])) * (position - Double(first))
    }
}
