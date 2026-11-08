import AppKit
import CryptoKit
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import UsageHUD

private let renderedWeatherCases: [CruiseWeather] = [.sunny, .cloudy, .rain, .storm, .thunder, .typhoon, .snow, .night]
// The authored thunder envelope peaks at 2.00 s and is absent at 0.00 s.
// The 24-frame, six-second exports sample this peak exactly.
private let thunderStrikeTime: TimeInterval = 2
private let thunderRestTime: TimeInterval = 0

/// Real GPU output, rather than a screenshot of a placeholder or shader source.
/// The small contract check runs normally. Full-size PNGs and streamed GIFs are
/// opt-in: USAIGE_RENDER_WEATHER=/absolute/path swift test --filter CruiseWeatherRender
@Suite("CruiseWeatherRender")
@MainActor
struct CruiseWeatherRenderTests {
    @Test func weatherRendererProducesDistinctVisiblePixels() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Metal weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no renderer diagnostic")")
        let size = CGSize(width: 128, height: 96)
        var styles = Set<Data>()
        for weather in renderedWeatherCases {
            let optionalImage = renderer.snapshot(size: size, time: 0, weather: weather, dark: false, compact: false)
            let image = try #require(optionalImage, "\(weather.title) must render")
            #expect(image.width == 128 && image.height == 96)
            let pixels = try weatherPixels(image)
            #expect(weatherVisiblePixels(pixels) > 128, "\(weather.title) must contain visible pixels")
            styles.insert(Data(SHA256.hash(data: pixels)))
        }
        #expect(styles.count == renderedWeatherCases.count, "Each weather choice must change the rendered scene")
    }

    @Test func thunderLightningCanBeSuppressedWithoutRemovingTheWeather() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Metal weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no renderer diagnostic")")
        let size = CGSize(width: 192, height: 128)
        for dark in [false, true] {
            let optionalStrike = renderer.snapshot(size: size, time: thunderStrikeTime, weather: .thunder,
                                                   dark: dark, compact: false, lightningEnabled: true)
            let strike = try #require(optionalStrike)
            let optionalSuppressed = renderer.snapshot(size: size, time: thunderStrikeTime, weather: .thunder,
                                                       dark: dark, compact: false, lightningEnabled: false)
            let suppressed = try #require(optionalSuppressed)
            let optionalRest = renderer.snapshot(size: size, time: thunderRestTime, weather: .thunder,
                                                 dark: dark, compact: false, lightningEnabled: true)
            let rest = try #require(optionalRest)
            let optionalSuppressedRest = renderer.snapshot(size: size, time: thunderRestTime, weather: .thunder,
                                                           dark: dark, compact: false, lightningEnabled: false)
            let suppressedRest = try #require(optionalSuppressedRest)
            let strikePixels = try weatherPixels(strike)
            let suppressedPixels = try weatherPixels(suppressed)
            let restPixels = try weatherPixels(rest)
            let suppressedRestPixels = try weatherPixels(suppressedRest)
            #expect(strike.width == 192 && strike.height == 128)
            #expect(weatherChangedBytes(strikePixels, suppressedPixels) > 100,
                    "The authored thunder peak must visibly add a bolt and illumination")
            #expect(weatherChangedBytes(strikePixels, suppressedPixels, minimumDelta: 4) > 100,
                    "Lightning must exceed small GPU/readback rounding differences")
            #expect(weatherChangedBytes(strikePixels, restPixels) > 100,
                    "Thunder must include an intermittent strike, rather than a permanent flash")
            // Equivalent shader branches and color conversion need not land
            // on the same side of every 8-bit rounding boundary on all GPUs.
            // Permit only imperceptible quantization noise, never a glow or
            // changed scene; the strike assertion above requires real contrast.
            let restError = weatherChannelError(restPixels, suppressedRestPixels)
            #expect(restError.maximum <= 2 && restError.mean <= 0.5,
                    "Rest-phase lightning suppression changed the scene: max channel error \(restError.maximum), mean \(restError.mean)")
            #expect(suppressedPixels.count == 192 * 128 * 4)
            #expect(weatherVisiblePixels(suppressedPixels) > 192 * 128 / 2,
                    "Suppressing lightning must keep the cloudy, rainy sea visible")
            #expect(Set(suppressedPixels).count > 8,
                    "Lightning suppression must preserve a detailed weather scene")
        }
    }

    @Test func typhoonRendersItsOwnSceneRatherThanReusingStorm() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Metal weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no renderer diagnostic")")
        let size = CGSize(width: 192, height: 128)
        for compact in [false, true] {
            let optionalTyphoon = renderer.snapshot(size: size, time: 1.3, weather: .typhoon,
                                                    dark: false, compact: compact)
            let typhoon = try #require(optionalTyphoon)
            let optionalStorm = renderer.snapshot(size: size, time: 1.3, weather: .storm,
                                                  dark: false, compact: compact)
            let storm = try #require(optionalStorm)
            let typhoonPixels = try weatherPixels(typhoon)
            let stormPixels = try weatherPixels(storm)
            #expect(weatherVisiblePixels(typhoonPixels) > 192 * 128 / 2)
            #expect(weatherChangedBytes(typhoonPixels, stormPixels) > 100,
                    "Typhoon's rotating wind and sea profile must be visually distinct from Storm")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_WEATHER"] != nil))
    func exportsWeatherAtBothSizesAndAppearances() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Metal weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no renderer diagnostic")")
        let directory = try weatherOutputDirectory()
        let layouts: [(name: String, size: CGSize, compact: Bool)] = [
            ("large", CGSize(width: 960, height: 560), false),
            ("compact", CGSize(width: 128, height: 192), true),
        ]
        var receipts: [[String: Any]] = []
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            var contactImages: [CGImage] = []
            for layout in layouts {
                var styles = Set<Data>()
                for weather in renderedWeatherCases {
                    let result = try autoreleasepool { () throws -> (image: CGImage, receipt: [String: Any], digest: Data) in
                        let baselineTime: TimeInterval = weather == .thunder ? thunderStrikeTime : 0
                        let comparisonTime = baselineTime + 1.3
                        let optionalStill = renderer.snapshot(size: layout.size, time: baselineTime, weather: weather,
                                                              dark: dark, compact: layout.compact)
                        let still = try #require(optionalStill, "\(weather.title), \(appearance), \(layout.name)")
                        let optionalMoved = renderer.snapshot(size: layout.size, time: comparisonTime, weather: weather,
                                                              dark: dark, compact: layout.compact)
                        let moved = try #require(optionalMoved)
                        #expect(still.width == Int(layout.size.width) && still.height == Int(layout.size.height))
                        #expect(moved.width == still.width && moved.height == still.height)
                        let baseline = try weatherPixels(still)
                        let later = try weatherPixels(moved)
                        let visible = weatherVisiblePixels(baseline)
                        let changed = weatherChangedBytes(baseline, later)
                        #expect(visible > still.width * still.height / 100,
                                "\(weather.title) must render visible weather in \(layout.name)")
                        #expect(changed >= (layout.compact ? 1 : 100),
                                "\(weather.title) must visibly animate in \(appearance), \(layout.name); changed \(changed) bytes")
                        let filename = "weather-\(weather.rawValue)-\(appearance)-\(layout.name).png"
                        try weatherWritePNG(still, to: directory.appendingPathComponent(filename))
                        return (still, ["weather": weather.rawValue, "appearance": appearance,
                                        "layout": layout.name, "width": still.width, "height": still.height,
                                        "visiblePixels": visible, "baselineTimeSeconds": baselineTime,
                                        "comparisonTimeSeconds": comparisonTime, "changedBytesAfter1_3Seconds": changed,
                                        "png": filename], Data(SHA256.hash(data: baseline)))
                    }
                    receipts.append(result.receipt)
                    styles.insert(result.digest)
                    if !layout.compact { contactImages.append(result.image) }
                }
                #expect(styles.count == renderedWeatherCases.count,
                        "All \(renderedWeatherCases.count) weather scenes must differ in \(appearance), \(layout.name)")
            }
            let contact = try weatherContactSheet(images: contactImages, dark: dark)
            try weatherWritePNG(contact, to: directory.appendingPathComponent("weather-contact-\(appearance).png"))
        }
        let data = try JSONSerialization.data(withJSONObject: ["renders": receipts], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("weather-render-verification.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_WEATHER"] != nil))
    func exportsAllWeatherAnimations() throws {
        guard #available(macOS 14.0, *), let device = MTLCreateSystemDefaultDevice() else { return }
        let optionalRenderer = CruiseWeatherRenderer(device: device)
        let renderer = try #require(optionalRenderer,
                                    "Metal weather shader setup failed: \(CruiseWeatherRenderer.lastError ?? "no renderer diagnostic")")
        let directory = try weatherOutputDirectory()
        let frameCount = 24
        let duration: TimeInterval = 6
        let size = CGSize(width: 640, height: 360)
        var receipts: [[String: Any]] = []
        for weather in renderedWeatherCases {
            let receipt = try autoreleasepool { () throws -> [String: Any] in
                let filename = "weather-\(weather.rawValue).gif"
                let optionalDestination = CGImageDestinationCreateWithURL(
                    directory.appendingPathComponent(filename) as CFURL, UTType.gif.identifier as CFString,
                    frameCount, nil
                )
                let destination = try #require(optionalDestination)
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0,
                ]] as CFDictionary)
                var poses = Set<Data>()
                for frame in 0..<frameCount {
                    try autoreleasepool {
                        let time = Double(frame) * duration / Double(frameCount)
                        let optionalImage = renderer.snapshot(size: size, time: time, weather: weather,
                                                              dark: false, compact: false)
                        let image = try #require(optionalImage)
                        let pixels = try weatherPixels(image)
                        poses.insert(Data(SHA256.hash(data: pixels)))
                        let delay = duration / Double(frameCount)
                        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFDelayTime: delay,
                            kCGImagePropertyGIFUnclampedDelayTime: delay,
                        ]] as CFDictionary)
                    }
                }
                #expect(poses.count >= 3, "\(weather.title) must show movement throughout its GIF")
                guard CGImageDestinationFinalize(destination) else { throw WeatherRenderError.encoding }
                return ["weather": weather.rawValue, "gif": filename, "frames": frameCount,
                        "durationSeconds": duration, "uniqueRenderedPoses": poses.count,
                        "containsAuthoredLightningPeak": weather == .thunder,
                        "width": Int(size.width), "height": Int(size.height)]
            }
            receipts.append(receipt)
        }
        let data = try JSONSerialization.data(withJSONObject: ["animations": receipts], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("weather-animation-verification.json"))
    }
}

@MainActor
private func weatherOutputDirectory() throws -> URL {
    let raw = try #require(ProcessInfo.processInfo.environment["USAIGE_RENDER_WEATHER"])
    try #require(raw.hasPrefix("/"), "Choose an absolute weather-render output directory")
    let directory = URL(fileURLWithPath: raw, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Canonical RGBA buffers make comparisons independent of source row padding,
/// Metal texture byte order, or ImageIO's encoded-file metadata.
private func weatherPixels(_ image: CGImage) throws -> Data {
    var bytes = Data(count: image.width * image.height * 4)
    let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drew else { throw WeatherRenderError.bitmap }
    return bytes
}

private func weatherVisiblePixels(_ pixels: Data) -> Int {
    pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        stride(from: 3, to: bytes.count, by: 4).reduce(into: 0) { count, offset in
            if bytes[offset] > 16 { count += 1 }
        }
    }
}

private func weatherChangedBytes(_ before: Data, _ after: Data, minimumDelta: Int = 0) -> Int {
    guard before.count == after.count else { return max(before.count, after.count) }
    return zip(before, after).reduce(into: 0) { count, pair in
        if abs(Int(pair.0) - Int(pair.1)) > minimumDelta { count += 1 }
    }
}

private func weatherChannelError(_ before: Data, _ after: Data) -> (maximum: Int, mean: Double) {
    guard before.count == after.count, !before.isEmpty else { return (255, 255) }
    var maximum = 0, total = 0
    for pair in zip(before, after) {
        let error = abs(Int(pair.0) - Int(pair.1))
        maximum = max(maximum, error)
        total += error
    }
    return (maximum, Double(total) / Double(before.count))
}

private func weatherWritePNG(_ image: CGImage, to url: URL) throws {
    let optionalDestination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    let destination = try #require(optionalDestination)
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw WeatherRenderError.encoding }
}

@MainActor
private func weatherContactSheet(images: [CGImage], dark: Bool) throws -> CGImage {
    try #require(images.count == renderedWeatherCases.count)
    let columns = 4, rows = (renderedWeatherCases.count + columns - 1) / columns
    let cellWidth = 480, cellHeight = 280, headerHeight = 48
    let width = columns * cellWidth, height = rows * cellHeight + headerHeight
    let optionalBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )
    let bitmap = try #require(optionalBitmap)
    let optionalContext = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = try #require(optionalContext)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor(calibratedWhite: dark ? 0.09 : 0.96, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let ink = NSColor(calibratedWhite: dark ? 0.94 : 0.15, alpha: 1)
    let heading = "CRUISE WEATHER · \(dark ? "DARK" : "LIGHT")"
    (heading as NSString).draw(at: NSPoint(x: 18, y: height - 32), withAttributes: [
        .font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: ink,
    ])
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    for (index, image) in images.enumerated() {
        let x = CGFloat(index % columns * cellWidth)
        let y = CGFloat(height - headerHeight - (index / columns + 1) * cellHeight)
        let availableWidth = CGFloat(cellWidth - 12), availableHeight = CGFloat(cellHeight - 33)
        let scale = min(availableWidth / CGFloat(image.width), availableHeight / CGFloat(image.height))
        let imageWidth = CGFloat(image.width) * scale, imageHeight = CGFloat(image.height) * scale
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)).draw(
            in: NSRect(x: x + (CGFloat(cellWidth) - imageWidth) / 2,
                       y: y + 27 + (availableHeight - imageHeight) / 2,
                       width: imageWidth, height: imageHeight)
        )
        (renderedWeatherCases[index].title as NSString).draw(
            in: NSRect(x: x + 6, y: y + 3, width: CGFloat(cellWidth - 12), height: 20), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: ink, .paragraphStyle: paragraph,
            ]
        )
    }
    let image = try #require(bitmap.cgImage)
    return image
}

private enum WeatherRenderError: Error { case bitmap, encoding }
