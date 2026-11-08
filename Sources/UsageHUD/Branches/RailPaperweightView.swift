import SwiftUI

/// The glass and readout stay still. One visible-hover clock drives the brief
/// liquid slosh and selects cached ship poses after the liquid has settled.
@available(macOS 14.0, *)
struct RailPaperweightView: View {
    let configuration: PaperweightConfiguration
    let ship: PaperweightShipKind
    let hovered: Bool
    @StateObject private var motion: RailPaperweightMotion
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(configuration: PaperweightConfiguration, ship: PaperweightShipKind, hovered: Bool) {
        self.configuration = configuration
        self.ship = ship
        self.hovered = hovered
        _motion = StateObject(wrappedValue: RailPaperweightMotion(configuration: configuration))
    }

    var body: some View {
        let glass = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            glass.fill(.white.opacity(0.07))
            glass.fill(LinearGradient(colors: [.white.opacity(0.12), .clear, .white.opacity(0.025)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            GeometryReader { geometry in
                let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 2, dy: 3)
                ForEach(Array(configuration.layers.enumerated()), id: \.element.id) { index, layer in
                    let color = Color(railHex: layer.colorHex)
                    RailLiquidBand(frame: motion.frame, layer: index, rect: rect)
                        .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.85)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if configuration.usedBytes > 0 {
                    RailLiquidEdge(frame: motion.frame, rect: rect)
                        .stroke(.white.opacity(0.55), lineWidth: 0.7)
                    let shipSize = CGSize(width: 18, height: 12)
                    RailPaperweightShipImage(kind: ship, size: shipSize, animationTime: motion.shipTime)
                        .rotationEffect(.radians(-motion.frame.boat.angle),
                                        anchor: UnitPoint(x: 0.5, y: RailPaperweightShipImage.waterlineFraction))
                        .position(x: rect.minX + rect.width * motion.frame.boat.x / PaperweightConstants.textureWidth,
                                  y: rect.maxY - rect.height * motion.frame.boat.y / PaperweightConstants.textureHeight
                                    + shipSize.height * (0.5 - RailPaperweightShipImage.waterlineFraction))
                }
            }
            .clipShape(glass)
            glass.strokeBorder(Color.primary.opacity(0.23), lineWidth: 0.8)
            Path { path in
                path.move(to: CGPoint(x: 8, y: 2))
                path.addLine(to: CGPoint(x: 56, y: 2))
            }
            .stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
        .frame(width: 64, height: HUDMetrics.resourcePaperweightHeight)
        // The rail's hover fade must not animate a ship after its hover ends.
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .background {
            RailPaperweightVisibility { visible in
                isVisible = visible
                updateMotion()
            }
        }
        .onAppear { updateMotion() }
        .onChange(of: configuration) { _, _ in updateMotion() }
        .onChange(of: hovered) { _, _ in updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
        .onChange(of: ship) { _, _ in motion.stop(); updateMotion() }
        .onDisappear { motion.stop() }
    }

    private func updateMotion() {
        motion.update(configuration: configuration, hovered: hovered && !reduceMotion,
                      visible: isVisible, animateShip: RailPaperweightShipImage.canAnimate)
    }
}

struct RailPaperweightFrame {
    let curves: [[Double]]
    let boat: PaperweightBoat

    init(_ simulation: PaperweightSimulation) {
        curves = simulation.currentLevels.indices.map { layer in
            (0..<PaperweightConstants.sampleCount).map { simulation.curve(layer: layer, sample: $0) }
        }
        var boat = simulation.boat
        // The mini block's bottom glass inset leaves room for the keel, so
        // shallow water needn't lift the ship away from its surface.
        let surface = simulation.surface(at: boat.x)
        if surface < PaperweightConstants.boatDraft {
            boat.y = surface + max(0, boat.y - PaperweightConstants.boatDraft)
        }
        self.boat = boat
    }
}

@MainActor
final class RailPaperweightMotion: ObservableObject {
    @Published private(set) var frame: RailPaperweightFrame
    @Published private(set) var shipTime: TimeInterval? = nil
    private let simulation: PaperweightSimulation
    private var hovered = false
    private var animation: Task<Void, Never>?
    private var generation = 0
    private var animatesShip = true
    private var startedAt: TimeInterval = 0

    init(configuration: PaperweightConfiguration) {
        let simulation = PaperweightSimulation(configuration: configuration, reservesLabelSpace: false)
        self.simulation = simulation
        frame = RailPaperweightFrame(simulation)
    }

    func update(configuration: PaperweightConfiguration, hovered: Bool,
                visible: Bool = true, animateShip: Bool = true) {
        let active = hovered && visible && configuration.usedBytes > 0
        let entered = active && !self.hovered
        self.hovered = active
        animatesShip = animateShip
        if !animateShip { shipTime = nil }
        simulation.update(configuration: configuration)
        if !active { stop(); return }
        if entered {
            simulation.shake(amplitude: 130)
            // Give pointer entry a visible first frame before the next wake.
            simulation.step(dt: 1.0 / 20)
            start()
        } else if animation == nil {
            if animatesShip { start() }
            else { simulation.settle() }
        }
        frame = RailPaperweightFrame(simulation)
    }

    func stop() {
        generation += 1
        animation?.cancel()
        animation = nil
        hovered = false
        shipTime = nil
        simulation.settle()
        frame = RailPaperweightFrame(simulation)
    }

    private func start() {
        animation?.cancel()
        generation += 1
        let current = generation
        startedAt = ProcessInfo.processInfo.systemUptime
        shipTime = animatesShip ? 0 : nil
        animation = Task { @MainActor [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                // No strong owner crosses the sleep. Discarding the view can
                // release this motion object even before an explicit stop.
                guard let delay = self?.advance(now: now, previous: previous, generation: current) else { return }
                previous = now
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    private func advance(now: TimeInterval, previous: TimeInterval, generation current: Int) -> TimeInterval? {
        guard hovered, generation == current else { return nil }
        if !simulation.isSettled {
            simulation.step(dt: min(0.05, max(1.0 / 120, now - previous)))
            frame = RailPaperweightFrame(simulation)
        }
        if animatesShip {
            let index = RailPaperweightShipTiming.frameIndex(at: now - startedAt)
            let time = Double(index) * RailPaperweightShipTiming.frameDuration
            if shipTime != time { shipTime = time }
        } else if simulation.isSettled {
            animation = nil
            return nil
        }
        // Once settled, keep the cached fluid frame and wake only when the
        // tiny sprite can advance. No grid stepping or curve reconstruction.
        return simulation.isSettled ? RailPaperweightShipTiming.frameDuration : 0.05
    }
}

private struct RailLiquidBand: Shape {
    let frame: RailPaperweightFrame
    let layer: Int
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        guard frame.curves.indices.contains(layer) else { return Path() }
        var path = Path()
        let upper = frame.curves[layer]
        let lower = layer > 0 ? frame.curves[layer - 1] : Array(repeating: 0, count: upper.count)
        for (index, value) in upper.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(upper.count - 1),
                                y: rect.maxY - rect.height * value / PaperweightConstants.textureHeight)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for index in lower.indices.reversed() {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * Double(index) / Double(lower.count - 1),
                                    y: rect.maxY - rect.height * lower[index] / PaperweightConstants.textureHeight))
        }
        path.closeSubpath()
        return path
    }
}

private struct RailLiquidEdge: Shape {
    let frame: RailPaperweightFrame
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        guard let top = frame.curves.last else { return Path() }
        var path = Path()
        for (index, value) in top.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(top.count - 1),
                                y: rect.maxY - rect.height * value / PaperweightConstants.textureHeight)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

extension Color {
    /// The paperweights' layer colours, shared by the rail and its cards.
    init(railHex: UInt32) {
        self.init(red: Double((railHex >> 16) & 255) / 255,
                  green: Double((railHex >> 8) & 255) / 255, blue: Double(railHex & 255) / 255)
    }
}
