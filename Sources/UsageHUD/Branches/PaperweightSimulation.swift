import Foundation

enum PaperweightConstants {
    static let BW = 4.0
    static let BH = 1.9
    static let BD = 1.1
    static let BR = 0.22
    static let innerWidth = 3.8
    static let innerHeight = 1.74
    static let textureWidth = 440.0
    static let unitsPerPixel = innerWidth / textureWidth
    static let textureHeight = innerHeight / unitsPerPixel
    static let sampleCount = 64
    static let dx = textureWidth / Double(sampleCount - 1)
    static let boatScale = 2.9
    // Reserve the tallest rolled mast and the deepest keel of all twelve ships.
    static let boatHeight = 25 * boatScale
    static let boatDraft = 28.0
    static let headroom = boatHeight + 8
    static let liquidHeight = textureHeight - headroom
    static let boatCeiling = textureHeight - boatHeight - 4
    // Long bowsprits need room even at the maximum roll angle.
    static let boatMargin = 68.0
    static let maximumRoll = 0.35
    static let X0 = -innerWidth / 2
    static let Y0 = -innerHeight / 2
    static let ZF = BD / 2 - 0.1
    static let ZB = -BD / 2 + 0.1
}

struct PaperweightBoat: Equatable, Sendable {
    var x = PaperweightConstants.textureWidth * 0.42
    var y = 0.0
    var velocityX = 0.0
    var velocityY = 0.0
    var angle = 0.0
    var angularVelocity = 0.0
}

/// The prototype's spring grid and boat run only when the owner asks for a
/// step. Keeping the physics apart from rendering makes stillness testable.
final class PaperweightSimulation {
    private let reservesLabelSpace: Bool
    private(set) var configuration: PaperweightConfiguration
    private(set) var currentLevels: [Double]
    private(set) var targetLevels: [Double]
    private(set) var waveHeights = Array(repeating: 0.0, count: PaperweightConstants.sampleCount)
    private var waveVelocities = Array(repeating: 0.0, count: PaperweightConstants.sampleCount)
    private var pendingDropSplash: Double?
    var boat = PaperweightBoat()
    var acceleration = 0.0
    var tiltTarget = 0.0
    private(set) var tilt = 0.0
    private var randomState: UInt64 = 0x5EED_120

    init(configuration: PaperweightConfiguration, reservesLabelSpace: Bool = true) {
        self.reservesLabelSpace = reservesLabelSpace
        self.configuration = configuration
        let levels = Self.layout(configuration.layers.map(\.bytes), configuration: configuration, reservesLabelSpace: reservesLabelSpace)
        currentLevels = levels
        targetLevels = levels
        boat.y = max(PaperweightConstants.boatDraft, surface(at: boat.x))
    }

    var energy: Double {
        let waves = waveVelocities.reduce(0) { $0 + $1 * $1 } / Double(PaperweightConstants.sampleCount)
        let changing = zip(targetLevels, currentLevels).reduce(0) { $0 + abs($1.0 - $1.1) }
        return waves + boat.velocityX * boat.velocityX * 0.05
            + boat.velocityY * boat.velocityY * 0.1
            + boat.angularVelocity * boat.angularVelocity * 50
            + changing * 5 + abs(tilt - tiltTarget) * 400 + abs(acceleration) * 400
            + (pendingDropSplash == nil ? 0 : 1)
    }

    var isSettled: Bool { energy < 0.25 }

    func step(dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        let duration = min(0.05, dt)
        let count = max(1, Int(ceil(duration * 120)))
        let interval = duration / Double(count)
        for _ in 0..<count { advance(interval) }
        if isSettled, abs(tiltTarget) < 0.0001, abs(acceleration) < 0.0001 { settle() }
    }

    func surface(at x: Double) -> Double {
        guard let top = currentLevels.last, top > 0 else { return 0 }
        return min(PaperweightConstants.boatCeiling, max(0, top + wave(at: x)))
    }

    func curve(layer: Int, sample: Int) -> Double {
        guard currentLevels.indices.contains(layer), let top = currentLevels.last, top > 0 else { return 0 }
        let index = min(max(0, sample), PaperweightConstants.sampleCount - 1)
        return max(0, currentLevels[layer] + waveHeights[index] * (currentLevels[layer] / top))
    }

    func shake(amplitude: Double) {
        guard amplitude.isFinite else { return }
        let strength = min(1_000, max(-1_000, amplitude))
        for index in waveVelocities.indices {
            waveVelocities[index] += strength * cos(.pi * Double(index) / Double(PaperweightConstants.sampleCount - 1))
        }
        // A repeatable impulse makes a physics regression reproducible.
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let random = Double(randomState >> 11) / Double(UInt64(1) << 53)
        boat.velocityX += (random - 0.5) * 160
    }

    func splash(x: Double) {
        guard x.isFinite else { return }
        let center = min(PaperweightConstants.textureWidth, max(0, x))
        for index in waveVelocities.indices {
            let distance = (Double(index) * PaperweightConstants.dx - center) / 24
            waveVelocities[index] -= 140 * exp(-distance * distance)
        }
    }

    func setBytes(_ bytes: [Int64]) {
        for index in configuration.layers.indices {
            configuration.layers[index].bytes = bytes.indices.contains(index) ? max(0, bytes[index]) : 0
        }
        if configuration.freeBytes != nil {
            configuration.freeBytes = max(0, configuration.capacityBytes - configuration.usedBytes)
        }
        targetLevels = Self.layout(configuration.layers.map(\.bytes), configuration: configuration, reservesLabelSpace: reservesLabelSpace)
    }

    func update(configuration: PaperweightConfiguration) {
        guard configuration != self.configuration else { return }
        var previousThickness: [String: Double] = [:]
        for index in self.configuration.layers.indices {
            previousThickness[self.configuration.layers[index].id] = currentLevels[index] - (index > 0 ? currentLevels[index - 1] : 0)
        }
        self.configuration = configuration
        targetLevels = Self.layout(configuration.layers.map(\.bytes), configuration: configuration, reservesLabelSpace: reservesLabelSpace)
        var cumulative = 0.0
        currentLevels = configuration.layers.enumerated().map { index, layer in
            let targetThickness = targetLevels[index] - (index > 0 ? targetLevels[index - 1] : 0)
            cumulative += previousThickness[layer.id] ?? targetThickness
            return cumulative
        }
        if cumulative > PaperweightConstants.liquidHeight {
            currentLevels = currentLevels.map { $0 / cumulative * PaperweightConstants.liquidHeight }
        }
        boundWaves()
        boundBoat()
    }

    /// Reduce Motion and an inactive scene use the final data immediately,
    /// with no spring left waiting for a later redraw.
    func settle() {
        currentLevels = targetLevels
        waveHeights = Array(repeating: 0, count: PaperweightConstants.sampleCount)
        waveVelocities = Array(repeating: 0, count: PaperweightConstants.sampleCount)
        tilt = 0
        tiltTarget = 0
        acceleration = 0
        pendingDropSplash = nil
        boat.velocityX = 0
        boat.velocityY = 0
        boat.angle = 0
        boat.angularVelocity = 0
        boundBoat()
        boat.y = max(PaperweightConstants.boatDraft, surface(at: boat.x))
    }

    /// Changing ships gives the same short drop and local dip as the prototype.
    func dropShip() {
        boat.y = min(PaperweightConstants.boatCeiling, surface(at: boat.x) + 48)
        boat.velocityY = -30
        // The scene's own clock can cancel the delayed impact when it settles.
        pendingDropSplash = 0.26
    }

    private func advance(_ dt: Double) {
        if let remaining = pendingDropSplash {
            if remaining <= dt {
                pendingDropSplash = nil
                splash(x: boat.x)
            } else {
                pendingDropSplash = remaining - dt
            }
        }
        if !tiltTarget.isFinite { tiltTarget = 0 }
        if !acceleration.isFinite { acceleration = 0 }
        tiltTarget = min(0.09, max(-0.09, tiltTarget))
        acceleration = min(1, max(-1, acceleration))
        tilt += (tiltTarget - tilt) * min(1, dt * 7)
        let tangent = tan(tilt) + acceleration
        for index in waveHeights.indices {
            let left = waveHeights[max(0, index - 1)]
            let right = waveHeights[min(PaperweightConstants.sampleCount - 1, index + 1)]
            let target = min(PaperweightConstants.textureHeight * 0.3,
                             max(-PaperweightConstants.textureHeight * 0.3,
                                 tangent * (Double(index) * PaperweightConstants.dx - PaperweightConstants.textureWidth / 2)))
            waveVelocities[index] = (waveVelocities[index]
                + (520 * (left + right - 2 * waveHeights[index]) + 9 * (target - waveHeights[index])) * dt) * 0.996
        }
        for index in waveHeights.indices { waveHeights[index] += waveVelocities[index] * dt }
        boundWaves()

        let slope = (surface(at: boat.x + 12) - surface(at: boat.x - 12)) / 24
        boat.velocityX = (boat.velocityX - 520 * (slope - tangent) * dt) * 0.995
        boat.x += boat.velocityX * dt
        if boat.x < PaperweightConstants.boatMargin {
            boat.x = PaperweightConstants.boatMargin
            boat.velocityX = abs(boat.velocityX) * 0.4
        }
        if boat.x > PaperweightConstants.textureWidth - PaperweightConstants.boatMargin {
            boat.x = PaperweightConstants.textureWidth - PaperweightConstants.boatMargin
            boat.velocityX = -abs(boat.velocityX) * 0.4
        }
        let surfaceY = surface(at: boat.x)
        boat.velocityY = (boat.velocityY + (surfaceY - boat.y) * 160 * dt) * 0.9
        boat.y += boat.velocityY * dt
        let targetAngle = min(PaperweightConstants.maximumRoll,
                              max(-PaperweightConstants.maximumRoll, atan(slope) - tilt)) + tilt
        boat.angularVelocity = (boat.angularVelocity + (targetAngle - boat.angle) * 90 * dt) * 0.88
        boat.angle += boat.angularVelocity * dt
        for index in currentLevels.indices {
            currentLevels[index] += (targetLevels[index] - currentLevels[index]) * min(1, dt * 2.5)
        }
        boundWaves()
        boundBoat()
    }

    private func boundWaves() {
        guard let top = currentLevels.last, top > 0 else {
            waveHeights = Array(repeating: 0, count: PaperweightConstants.sampleCount)
            waveVelocities = Array(repeating: 0, count: PaperweightConstants.sampleCount)
            return
        }
        let lower = min(3, top) - top
        let upper = PaperweightConstants.boatCeiling - top
        for index in waveHeights.indices {
            // The ship and the liquid use the same surface. Reserving its
            // height here keeps a crest from swallowing it or hitting the lid.
            waveHeights[index] = min(upper, max(lower, waveHeights[index]))
        }
    }

    private func boundBoat() {
        if !boat.x.isFinite { boat.x = PaperweightConstants.textureWidth * 0.42 }
        if !boat.y.isFinite { boat.y = surface(at: boat.x) }
        boat.x = min(PaperweightConstants.textureWidth - PaperweightConstants.boatMargin,
                     max(PaperweightConstants.boatMargin, boat.x))
        let water = max(PaperweightConstants.boatDraft, surface(at: boat.x))
        if boat.y < water { boat.y = water; boat.velocityY = max(0, boat.velocityY) }
        if boat.y > PaperweightConstants.boatCeiling {
            boat.y = PaperweightConstants.boatCeiling
            boat.velocityY = min(0, boat.velocityY)
        }
        let relative = min(PaperweightConstants.maximumRoll, max(-PaperweightConstants.maximumRoll, boat.angle - tilt))
        boat.angle = min(PaperweightConstants.maximumRoll, max(-PaperweightConstants.maximumRoll, tilt + relative))
    }

    private func wave(at x: Double) -> Double {
        let finiteX = x.isFinite ? x : 0
        let fraction = min(Double(PaperweightConstants.sampleCount - 1), max(0, finiteX / PaperweightConstants.dx))
        let index = min(PaperweightConstants.sampleCount - 2, Int(floor(fraction)))
        let blend = fraction - Double(index)
        return waveHeights[index] * (1 - blend) + waveHeights[index + 1] * blend
    }

    private static func layout(_ bytes: [Int64], configuration: PaperweightConfiguration, reservesLabelSpace: Bool) -> [Double] {
        guard configuration.capacityBytes > 0, bytes.contains(where: { $0 > 0 }) else { return bytes.map { _ in 0 } }
        let capacity = Double(configuration.capacityBytes)
        var thickness = bytes.enumerated().map { index, value in
            max(reservesLabelSpace ? (index == 0 && configuration.id == .storage ? 4 : 22) : 0,
                Double(max(0, value)) / capacity * PaperweightConstants.liquidHeight)
        }
        if reservesLabelSpace, configuration.id == .storage, !thickness.isEmpty {
            let used = min(1, Double(PaperweightData.total(bytes)) / capacity) * PaperweightConstants.liquidHeight
            thickness[0] = max(4, used - thickness.dropFirst().reduce(0, +))
        }
        let sum = thickness.reduce(0, +)
        if sum > PaperweightConstants.liquidHeight {
            thickness = thickness.map { $0 / sum * PaperweightConstants.liquidHeight }
        }
        var cumulative = 0.0
        return thickness.map { cumulative += $0; return cumulative }
    }
}
