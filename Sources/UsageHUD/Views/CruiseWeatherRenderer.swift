import AppKit
import MetalKit

/// Explicit draws share the scene's visibility-owned clock. The Metal view
/// never starts a second display loop and keeps at most two frames in flight.
@available(macOS 14.0, *)
@MainActor
final class CruiseWeatherRenderer: NSObject, @preconcurrency MTKViewDelegate {
    private struct Resources {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var weather: UInt32
        var dark: Float
        var compact: Float
        var allowsLightning: Float = 1
        var padding: Float = 0
        var sea: SIMD4<Float>
    }

    private static var resources: [UInt64: Resources] = [:]
    private(set) static var lastError: String?
    private let resource: Resources
    private let inFlight = DispatchSemaphore(value: 2)
    private var time: TimeInterval = 0
    private var weather = CruiseWeather.sunny
    private var dark = false
    private var compact = false
    private var lightningEnabled = true

    init?(device suppliedDevice: MTLDevice? = nil) {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice() else { return nil }
        if let cached = Self.resources[device.registryID] {
            resource = cached
        } else {
            do {
                let source = "#include <metal_stdlib>\nusing namespace metal;\n"
                    + CruiseCloudShader.source + "\n" + CruiseWeatherShader.source
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "cruiseWeatherVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "cruiseWeatherFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                guard let queue = device.makeCommandQueue() else { return nil }
                resource = Resources(device: device, queue: queue, pipeline: pipeline)
                if Self.resources.count >= 2 { Self.resources.removeAll() }
                Self.resources[device.registryID] = resource
            } catch {
                Self.lastError = String(describing: error)
                return nil
            }
        }
        super.init()
    }

    func configure(time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool, lightningEnabled: Bool = true) {
        self.time = time.isFinite ? time : 0
        self.weather = weather
        self.dark = dark
        self.compact = compact
        self.lightningEnabled = lightningEnabled
    }

    func attach(to view: MTKView) {
        view.device = resource.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = self
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = resource.queue.makeCommandBuffer() else { return }
        var uniforms = makeUniforms(size: view.drawableSize, time: time, weather: weather, dark: dark,
                                    compact: compact, lightningEnabled: lightningEnabled)
        guard encode(pass: pass, command: command, uniforms: &uniforms) else { return }
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable)
        command.commit()
        committed = true
    }

    /// Offscreen readback is only for gallery exports and visual qualification.
    /// Live animation presents GPU drawables without copying pixels to the CPU.
    func snapshot(size: CGSize, time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool,
                  lightningEnabled: Bool = true) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = min(2_048, max(1, Int(size.width.rounded())))
        let height = min(2_048, max(1, Int(size.height.rounded())))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = resource.device.makeTexture(descriptor: descriptor),
              let command = resource.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var uniforms = makeUniforms(size: CGSize(width: width, height: height), time: time,
                                    weather: weather, dark: dark, compact: compact, lightningEnabled: lightningEnabled)
        guard encode(pass: pass, command: command, uniforms: &uniforms) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { Self.lastError = command.error?.localizedDescription; return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space, bitmapInfo: bitmap, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, uniforms: inout Uniforms) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(resource.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func makeUniforms(size: CGSize, time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool,
                              lightningEnabled: Bool) -> Uniforms {
        let condition: UInt32
        switch weather {
        case .sunny: condition = 0
        case .cloudy: condition = 1
        case .rain: condition = 2
        case .storm: condition = 3
        case .snow: condition = 4
        case .automatic, .night: condition = 5
        case .thunder: condition = 6
        case .typhoon: condition = 7
        }
        return Uniforms(resolution: SIMD2(Float(max(1, size.width)), Float(max(1, size.height))),
                        time: time.isFinite ? Float(time.truncatingRemainder(dividingBy: 3_600)) : 0,
                        weather: condition, dark: dark ? 1 : 0, compact: compact ? 1 : 0,
                        allowsLightning: lightningEnabled ? 1 : 0,
                        sea: weather.seaProfile.spectrum)
    }
}
