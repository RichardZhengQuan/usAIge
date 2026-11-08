import AppKit
import Metal
import Testing
@testable import UsageHUD

@Suite("Resource ocean shader")
struct ResourceOceanShaderTests {
    @Test func payloadPreservesCapacityAndTheSameSampledPhysicalWaterline() {
        let size = CGSize(width: 640, height: 400)
        let configuration = shaderOceanFixture(redFirst: true)
        let payload = ResourceOceanRenderData(configuration: configuration, size: size) { x in
            220 + sin(x / 640 * .pi * 2) * 24
        }
        #expect(payload.layers.count == 3)
        #expect(abs(payload.layers[0].w - 0.4) < 0.000_001)
        #expect(abs(payload.layers[1].w - 0.8) < 0.000_001)
        #expect(payload.layers[2].w == 1)
        #expect(payload.surface.count == 65)
        for index in 0..<65 {
            let fraction = Double(index) / 64
            let expectedSurface = 220 + sin(fraction * .pi * 2) * 24
            let sampledSurface = payload.surfaceFraction(at: fraction) * 400
            #expect(abs(sampledSurface - expectedSurface) < 0.0001)
            for band in ResourceOceanLayout(configuration: configuration).bands {
                let boundary = ResourceOceanLayout.boundary(at: band.end, surface: sampledSurface, bottom: 400)
                let shaderDepth = (boundary / 400 - payload.surfaceFraction(at: fraction))
                    / (1 - payload.surfaceFraction(at: fraction))
                #expect(abs(shaderDepth - band.end) < 0.000_001)
            }
        }
    }

    @Test func payloadRemainsBoundedAndIncludesEveryCategoryWhenFutureToolsExceedTheLimit() {
        let layers = (0..<24).map { index in
            PaperweightLayer(id: "tool-\(index)", title: "Tool \(index)", bytes: 10,
                             colorHex: index.isMultiple(of: 2) ? 0xFF0000 : 0x0000FF, inkHex: 0)
        }
        let payload = ResourceOceanRenderData(configuration: .init(id: .memory, capacityBytes: 240, layers: layers, freeBytes: 0),
                                              size: CGSize(width: 640, height: 400), surface: { _ in .nan })
        #expect(payload.layers.count == ResourceOceanRenderData.maximumLayerCount)
        #expect(payload.layers.last?.w == 1)
        #expect(payload.surface.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 })
        #expect(payload.layers.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    }

    @Test @MainActor func gpuPigmentFollowsCapacityBelowThePhysicalWaveAndKeepsSkyUncolored() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try #require(CruiseWeatherRenderer(device: device), "Resource ocean Metal setup must succeed")
        let size = CGSize(width: 480, height: 320)
        let wave: (Double) -> Double = { x in 170 + sin(x / 480 * .pi * 2) * 16 }
        let a = ResourceOceanRenderData(configuration: shaderOceanFixture(redFirst: true), size: size, surface: wave)
        let b = ResourceOceanRenderData(configuration: shaderOceanFixture(redFirst: false), size: size, surface: wave)
        let imageA = try #require(renderer.snapshot(size: size, time: 4, weather: .cloudy, dark: false,
                                                   compact: false, resourceOcean: a))
        let imageB = try #require(renderer.snapshot(size: size, time: 4, weather: .cloudy, dark: false,
                                                   compact: false, resourceOcean: b))
        let pixelsA = try shaderOceanPixels(imageA), pixelsB = try shaderOceanPixels(imageB)
        for x in [80, 240, 400] {
            let surface = a.surfaceFraction(at: Double(x) / 480) * 320
            let skyY = Int(surface - 12)
            #expect(shaderOceanRGB(pixelsA, x: x, y: skyY, width: 480) == shaderOceanRGB(pixelsB, x: x, y: skyY, width: 480))
            for depth in [0.2, 0.6] {
                let y = Int(surface + depth * (320 - surface))
                let left = shaderOceanRGB(pixelsA, x: x, y: y, width: 480)
                let right = shaderOceanRGB(pixelsB, x: x, y: y, width: 480)
                if depth < 0.4 {
                    #expect(left.z > right.z + 20 && left.x + 20 < right.x,
                            "The first capacity stratum must tint the actual shaded water below the wave")
                } else {
                    #expect(left.x > right.x + 20 && left.z + 20 < right.z,
                            "The second capacity stratum must start at the same proportional depth across x")
                }
            }
        }
        let animated = try #require(renderer.snapshot(size: size, time: 8, weather: .cloudy, dark: false,
                                                      compact: false, resourceOcean: a))
        let nextPixels = try shaderOceanPixels(animated)
        var changed = 0
        for y in 240..<300 {
            for x in stride(from: 10, to: 470, by: 8) {
                if shaderOceanRGB(pixelsA, x: x, y: y, width: 480) != shaderOceanRGB(nextPixels, x: x, y: y, width: 480) { changed += 1 }
            }
        }
        #expect(changed > 300, "Resource pigment must retain animated reflections and ripples throughout the water")
    }
}

private func shaderOceanFixture(redFirst: Bool) -> PaperweightConfiguration {
    PaperweightConfiguration(id: .storage, capacityBytes: 100, layers: [
        PaperweightLayer(id: "red", title: "First", bytes: 40, colorHex: redFirst ? 0xFF1005 : 0x0510FF, inkHex: 0),
        PaperweightLayer(id: "blue", title: "Second", bytes: 40, colorHex: redFirst ? 0x0510FF : 0xFF1005, inkHex: 0),
    ], freeBytes: 20)
}

private func shaderOceanPixels(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data)
    return Array(data as Data)
}

private func shaderOceanRGB(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> SIMD3<Int> {
    let offset = (y * width + x) * 4
    return SIMD3(Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset]))
}
