import AppKit
import MetalKit

/// Two GPU slots and one coalesced redraw request. Completion handlers use
/// this tiny lock-protected gate without touching AppKit or the renderer.
final class CruiseWeatherDrawAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var pending = false

    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < 2 else { pending = true; return false }
        inFlight += 1
        pending = false
        return true
    }

    /// Returns true once when a released slot can service a dropped redraw.
    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight > 0 else { return false }
        inFlight -= 1
        let retry = pending
        pending = false
        return retry
    }

    /// An uncommitted attempt has no completion of its own. Ask another real
    /// in-flight frame to retry it, or wait for the next normal visibility draw.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight > 0 else { return }
        inFlight -= 1
        pending = inFlight > 0
    }
}

/// Explicit draws share the scene's visibility-owned clock. The Metal view
/// never starts a second display loop and keeps at most two frames in flight.
@available(macOS 14.0, *)
@MainActor
final class CruiseWeatherRenderer: NSObject, MTKViewDelegate {
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
        var nextWeather: UInt32
        var sea: SIMD4<Float>
        var transition: SIMD4<Float>
        var weatherWeightsLow: SIMD4<Float>
        var weatherWeightsHigh: SIMD4<Float>
        var resourceOcean: SIMD4<Float>
    }

    private static var resources: [UInt64: Resources] = [:]
    private(set) static var lastError: String?
    private let resource: Resources
    private let drawAdmission = CruiseWeatherDrawAdmission()
    private weak var pendingView: MTKView?
    private var time: TimeInterval = 0
    private var weather = CruiseWeather.sunny
    private var dark = false
    private var compact = false
    private var lightningEnabled = true
    private var transition: CruiseWeatherTransition?
    private var seaProfile: CruiseSeaProfile?
    private var oceanTime: TimeInterval?
    private var mix: CruiseWeatherMix?
    private var resourceOcean: ResourceOceanRenderData?

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

    func configure(time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool,
                   lightningEnabled: Bool = true, transition: CruiseWeatherTransition? = nil,
                   seaProfile: CruiseSeaProfile? = nil, oceanTime: TimeInterval? = nil, mix: CruiseWeatherMix? = nil,
                   resourceOcean: ResourceOceanRenderData? = nil) {
        self.time = time.isFinite ? time : 0
        self.weather = weather
        self.dark = dark
        self.compact = compact
        self.lightningEnabled = lightningEnabled
        self.transition = transition
        self.seaProfile = seaProfile
        self.oceanTime = oceanTime
        self.mix = mix
        self.resourceOcean = resourceOcean
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
        // Publish the weak target before admission so a completion racing
        // this request can find the latest pending frame.
        pendingView = view
        guard drawAdmission.request() else { return }
        var committed = false
        defer { if !committed { drawAdmission.abandon() } }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = resource.queue.makeCommandBuffer() else { return }
        var uniforms = makeUniforms(size: view.drawableSize, time: time, weather: weather, dark: dark,
                                    compact: compact, lightningEnabled: lightningEnabled,
                                    transition: transition, seaProfile: seaProfile, oceanTime: oceanTime, mix: mix,
                                    resourceOcean: resourceOcean)
        guard encode(pass: pass, command: command, uniforms: &uniforms, resourceOcean: resourceOcean) else { return }
        let admission = drawAdmission
        command.addCompletedHandler { [weak self] _ in
            guard admission.complete() else { return }
            Task { @MainActor [weak self] in self?.retryPendingDraw() }
        }
        command.present(drawable)
        command.commit()
        committed = true
        pendingView = nil
    }

    private func retryPendingDraw() {
        guard let view = pendingView else { return }
        guard (view.delegate as AnyObject?) === self else { pendingView = nil; return }
        // Use the newest configuration, not a captured animated frame. This
        // is one completion-driven retry; it never starts a display clock.
        view.draw()
    }

    /// Offscreen readback is only for gallery exports and visual qualification.
    /// Live animation presents GPU drawables without copying pixels to the CPU.
    func snapshot(size: CGSize, time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool,
                  lightningEnabled: Bool = true, transition: CruiseWeatherTransition? = nil,
                  seaProfile: CruiseSeaProfile? = nil, oceanTime: TimeInterval? = nil, mix: CruiseWeatherMix? = nil,
                  resourceOcean: ResourceOceanRenderData? = nil) -> CGImage? {
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
                                    weather: weather, dark: dark, compact: compact, lightningEnabled: lightningEnabled,
                                    transition: transition, seaProfile: seaProfile, oceanTime: oceanTime, mix: mix,
                                    resourceOcean: resourceOcean)
        guard encode(pass: pass, command: command, uniforms: &uniforms, resourceOcean: resourceOcean) else { return nil }
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

    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, uniforms: inout Uniforms,
                        resourceOcean: ResourceOceanRenderData?) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(resource.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let pigments = resourceOcean?.layers ?? [.zero]
        let surface = resourceOcean?.surface ?? [0.61]
        pigments.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        surface.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func makeUniforms(size: CGSize, time: TimeInterval, weather: CruiseWeather, dark: Bool, compact: Bool,
                              lightningEnabled: Bool, transition: CruiseWeatherTransition?,
                              seaProfile: CruiseSeaProfile?, oceanTime: TimeInterval?, mix: CruiseWeatherMix?,
                              resourceOcean: ResourceOceanRenderData?) -> Uniforms {
        let sample = transition ?? CruiseWeatherTransition(from: weather, to: weather, progress: 0)
        let mixture = mix ?? CruiseWeatherMix(transition: sample)
        let profile = seaProfile ?? mixture.seaProfile
        let progress = sample.progress.isFinite ? min(1, max(0, sample.progress)) : 0
        let waveTime = oceanTime ?? time * Double(profile.speed) * (0.8 + Double(profile.roughness) * 0.65)
        return Uniforms(resolution: SIMD2(Float(max(1, size.width)), Float(max(1, size.height))),
                        time: time.isFinite ? Float(time.truncatingRemainder(dividingBy: 3_600)) : 0,
                        weather: conditionID(sample.from), dark: dark ? 1 : 0, compact: compact ? 1 : 0,
                        allowsLightning: lightningEnabled ? 1 : 0, nextWeather: conditionID(sample.to),
                        sea: profile.spectrum,
                        transition: SIMD4(Float(progress), Float(waveTime.isFinite ? waveTime : 0), 0, 0),
                        weatherWeightsLow: SIMD4(Float(mixture.weights[0]), Float(mixture.weights[1]),
                                                 Float(mixture.weights[2]), Float(mixture.weights[3])),
                        weatherWeightsHigh: SIMD4(Float(mixture.weights[4]), Float(mixture.weights[5]),
                                                  Float(mixture.weights[6]), Float(mixture.weights[7])),
                        resourceOcean: SIMD4(Float(resourceOcean?.layers.count ?? 0),
                                             Float(resourceOcean?.surface.count ?? 0), 0, 0))
    }

    private func conditionID(_ weather: CruiseWeather) -> UInt32 {
        switch weather {
        case .sunny: 0
        case .cloudy: 1
        case .rain: 2
        case .storm: 3
        case .snow: 4
        case .automatic, .night: 5
        case .thunder: 6
        case .typhoon: 7
        }
    }
}
