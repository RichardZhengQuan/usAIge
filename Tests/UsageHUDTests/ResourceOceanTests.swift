import AppKit
import Testing
@testable import UsageHUD

@Suite("Resource ocean")
struct ResourceOceanTests {
    @Test func oceanPreservesCapacityAndVerySmallCategories() throws {
        let configuration = resourceOceanFixture(capacity: 1_000, amounts: [100, 1], free: 899)
        let layout = ResourceOceanLayout(configuration: configuration)
        #expect(layout.bands.map(\.layer.id) == ["layer-1", "layer-0", "free"])
        #expect(abs(try #require(layout.bands.first).end - 0.001) < 0.000_001)
        #expect(layout.bands.last?.end == 1)
        for pair in zip(layout.bands, layout.bands.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        #expect(abs(layout.bands[1].end - layout.bands[1].start - 0.1) < 0.000_001)
    }

    @Test func layerSelectionFollowsTheDrawnWaveAtEveryDepth() {
        let layout = ResourceOceanLayout(configuration: resourceOceanFixture(capacity: 100, amounts: [40, 20], free: 40))
        for surface in [170.0, 244.0, 275.0] {
            for band in layout.bands {
                let middle = (band.start + band.end) * 0.5
                let y = ResourceOceanLayout.boundary(at: middle, surface: surface, bottom: 400)
                #expect(layout.layer(at: CGPoint(x: 300, y: y), size: CGSize(width: 600, height: 400), surface: surface)?.id == band.layer.id)
            }
            #expect(layout.layer(at: CGPoint(x: 300, y: surface - 1), size: CGSize(width: 600, height: 400), surface: surface) == nil)
            #expect(layout.layer(at: CGPoint(x: -1, y: 399), size: CGSize(width: 600, height: 400), surface: surface) == nil)
        }
    }

    @Test func unavailableCapacityShowsNeutralMeasuringWater() {
        let configuration = resourceOceanFixture(capacity: 100, amounts: [40, 20], free: nil)
        let layout = ResourceOceanLayout(configuration: configuration)
        #expect(layout.bands.count == 1)
        #expect(layout.bands[0].layer.isMeasuring)
        #expect(layout.bands[0].start == 0 && layout.bands[0].end == 1)
    }

    @Test func overlappingEstimatesStayInsideTheOcean() {
        let layout = ResourceOceanLayout(configuration: resourceOceanFixture(capacity: 100, amounts: [80, 80], free: 0))
        #expect(layout.bands.count == 2)
        #expect(layout.bands[0].end == 0.5)
        #expect(layout.bands[1].end == 1)
        #expect(layout.bands.allSatisfy { $0.start >= 0 && $0.end <= 1 })
    }

    @Test @MainActor func clickingNativeWaterSelectsItsLayerWhilePaused() throws {
        guard #available(macOS 14.0, *) else { return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = container
        let view = UsageAtmosphereView(frame: CGRect(x: 80, y: 150, width: 600, height: 400))
        container.addSubview(view)
        defer { view.stop(); window.contentView = nil }
        var selected: [String] = []
        view.configureOcean(configuration: resourceOceanFixture(capacity: 100, amounts: [40, 20], free: 40),
                            selectedLayerID: "layer-0", onSelect: { selected.append($0) })
        view.configure(active: false, compact: false, weather: .sunny, ship: .galleon, showsShip: true,
                       dark: false, reduced: true)
        for point in [CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 399)] {
            let location = view.convert(point, to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0))
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
        #expect(selected == ["layer-0", "free"])
        #expect(!view.isAnimating)
    }

    @Test @MainActor func nativeOceanUsesTheSailingSurfaceAndStopsWithoutAWindow() {
        guard #available(macOS 14.0, *) else { return }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let view = UsageAtmosphereView(frame: CGRect(x: 80, y: 150, width: 600, height: 400))
        container.addSubview(view)
        defer { view.stop() }
        view.configureOcean(configuration: resourceOceanFixture(capacity: 100, amounts: [40, 20], free: 40),
                            selectedLayerID: "layer-0", onSelect: { _ in })
        view.configure(active: true, compact: false, weather: .sunny, ship: .galleon, showsShip: true,
                       dark: false, reduced: true)
        #expect(view.hitTest(CGPoint(x: 380, y: 450)) === view)
        #expect(view.hitTest(CGPoint(x: 40, y: 450)) == nil)
        #expect(view.resourceLayer(at: CGPoint(x: 300, y: 20)) == nil)
        #expect(view.resourceLayer(at: CGPoint(x: 300, y: 399))?.id == "free")
        #expect(view.resourceLayer(at: CGPoint(x: 300, y: 300))?.id == "layer-0")
        #expect(!view.isAnimating)
        let time = view.animationTime
        view.advanceAnimation(by: 0.25)
        #expect(view.animationTime == time)
        #expect(view.accessibilityCustomActions()?.count == 3)
    }

    @Test @MainActor func clickingDisplacedThinLabelSelectsItsNamedLayerInsteadOfTheWaterBehindIt() throws {
        guard #available(macOS 14.0, *) else { return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = container
        let view = UsageAtmosphereView(frame: CGRect(x: 80, y: 150, width: 900, height: 240))
        container.addSubview(view)
        defer { view.stop(); window.contentView = nil }
        var selected: [String] = []
        view.configureOcean(configuration: resourceOceanFixture(capacity: 1_000_000, amounts: [1, 1], free: 999_998),
                            selectedLayerID: "layer-0", onSelect: { selected.append($0) })
        view.configure(active: false, compact: false, weather: .sunny, ship: .galleon, showsShip: true,
                       dark: false, reduced: true)
        for id in ["layer-0", "layer-1"] {
            let label = try #require(view.resourceLabelPlacements.first { $0.layerID == id })
            let point = CGPoint(x: label.frame.midX, y: label.frame.midY)
            #expect(point.y > label.anchor.y + 4,
                    "The fixture must put readable text below its subpixel capacity stratum")
            #expect(view.resourceLayer(at: point)?.id == id)
            let location = view.convert(point, to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0))
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
        #expect(selected == ["layer-0", "layer-1"])
        #expect(!view.isAnimating)
    }

    @Test @MainActor func resourceWeatherBlendsOnTheExistingSceneClock() {
        guard #available(macOS 14.0, *) else { return }
        let view = UsageAtmosphereView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.stop() }
        var now = 0.0
        view.weatherNow = { now }
        view.configureOcean(configuration: resourceOceanFixture(capacity: 100, amounts: [40, 20], free: 40),
                            selectedLayerID: "layer-0", onSelect: { _ in })
        view.configure(active: true, compact: false, weather: .sunny, ship: .galleon, showsShip: true,
                       dark: false, reduced: false)
        let sunny = view.weatherMix
        now = 1
        view.configure(active: true, compact: false, weather: .storm, ship: .galleon, showsShip: true,
                       dark: false, reduced: false)
        #expect(view.weatherMix == sunny, "A resource status change must keep the current water under the hull")
        for halfSecond in 1...12 {
            now = 1 + Double(halfSecond) * 0.5
            view.advanceAnimation(by: 1.0 / 24)
            if halfSecond == 6 {
                #expect(view.weatherMix != sunny)
                #expect(view.weatherMix != CruiseWeatherMix(transition: .init(from: .storm, to: .storm, progress: 0)))
            }
        }
        #expect(view.weatherMix == CruiseWeatherMix(transition: .init(from: .storm, to: .storm, progress: 0)))
        #expect(!view.isAnimating, "An offscreen resource scene must not introduce a weather timer")
    }

    @Test @MainActor func stoppedResourceScenesHoldWeatherAndBlendAfterResuming() {
        guard #available(macOS 14.0, *) else { return }
        for state in [(active: false, reduced: false, frozen: false),
                      (active: true, reduced: true, frozen: false),
                      (active: true, reduced: true, frozen: true)] {
            let view = UsageAtmosphereView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            defer { view.stop() }
            var now = 0.0
            view.weatherNow = { now }
            view.configureOcean(configuration: resourceOceanFixture(capacity: 100, amounts: [40, 20], free: 40),
                                selectedLayerID: "layer-0", onSelect: { _ in })
            view.configure(active: true, compact: false, weather: .sunny, ship: .galleon, showsShip: true,
                           dark: false, reduced: false)
            now = 1
            view.configure(active: true, compact: false, weather: .rain, ship: .galleon, showsShip: true,
                           dark: false, reduced: false)
            now = 1.5
            view.advanceAnimation(by: 1.0 / 24)
            let held = view.weatherMix
            now = 50
            view.configure(active: state.active, compact: false, weather: .storm, ship: .galleon, showsShip: true,
                           dark: true, reduced: state.reduced, capturesWeather: state.frozen)
            view.advanceAnimation(by: 0.25)
            #expect(view.weatherMix == held)
            #expect(!view.isAnimating)
            now = 100
            view.configure(active: true, compact: false, weather: .storm, ship: .galleon, showsShip: true,
                           dark: true, reduced: false)
            #expect(view.weatherMix == held)
            for halfSecond in 1...12 {
                now = 100 + Double(halfSecond) * 0.5
                view.advanceAnimation(by: 1.0 / 24)
            }
            #expect(view.weatherMix == CruiseWeatherMix(transition: .init(from: .storm, to: .storm, progress: 0)))
        }
    }
}

private func resourceOceanFixture(capacity: Int64, amounts: [Int64], free: Int64?) -> PaperweightConfiguration {
    PaperweightConfiguration(id: .storage, capacityBytes: capacity, layers: amounts.enumerated().map { index, bytes in
        PaperweightLayer(id: "layer-\(index)", title: "Layer \(index)", bytes: bytes, colorHex: 0x5E9FE3, inkHex: 0x042C53)
    }, freeBytes: free)
}
