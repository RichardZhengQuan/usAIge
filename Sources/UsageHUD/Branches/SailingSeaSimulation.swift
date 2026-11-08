import Foundation

/// The drawn water and boat share this surface. Coordinates use AppKit's
/// flipped drawing space, so a smaller boat y is above the water.
final class SailingSeaSimulation {
    private(set) var time = 0.0
    private(set) var boat = PaperweightBoat(x: 0, y: 0)
    private(set) var shipSize = CGSize.zero

    var waterlineFraction: Double {
        let top = PaperweightConstants.boatHeight * PaperweightConstants.unitsPerPixel + 0.02
        let bottom = PaperweightConstants.boatDraft * PaperweightConstants.unitsPerPixel + 0.02
        return top / (top + bottom)
    }

    private var size = CGSize.zero
    private var compact = false
    private var weather = CruiseWeather.sunny
    private var shakeHeight = 0.0
    private var shakeVelocity = 0.0
    private var shakeSequence = 0
    private var hasArea: Bool { size.width > 0 && size.height > 0 }
    private var period: Double { compact ? 25 : 82 }
    private var baseWaterline: Double { Double(size.height) * (compact ? 0.79 : 0.61) }
    private var displacementLimit: Double { Double(size.height) * (compact ? 0.035 : 0.08) }
    private var padding: Double { min(2, Double(size.height) * 0.01) }
    private var supportSafety: Double { min(0.05, displacementLimit * 0.003) }

    func configure(size: CGSize, compact: Bool, weather: CruiseWeather) {
        let safeSize = CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
                              height: size.height.isFinite ? max(0, size.height) : 0)
        let layoutChanged = self.size != safeSize || self.compact != compact
        self.size = safeSize
        self.compact = compact
        self.weather = weather
        updateShipSize()
        guard hasArea else {
            boat = PaperweightBoat(x: 0, y: 0)
            shakeHeight = 0; shakeVelocity = 0
            return
        }
        shakeHeight = clamped(shakeHeight, -displacementLimit * 0.85, displacementLimit * 0.85)
        boat.x = cruiseX()
        if layoutChanged {
            boat.velocityY = 0
            boat.angularVelocity = 0
        }
        boundBoat(pinToSurface: layoutChanged)
    }

    func step(dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        // A resumed window never catches up minutes of hidden animation.
        let duration = min(0.25, dt)
        let count = max(1, Int(ceil(duration * 120)))
        let interval = duration / Double(count)
        for _ in 0..<count { advance(interval) }
    }

    func shake(amplitude: Double = 1) {
        guard hasArea, amplitude.isFinite, amplitude != 0 else { return }
        let strength = clamped(amplitude, -4, 4)
        let direction = (shakeSequence.isMultiple(of: 2) ? 1.0 : -1.0) * (strength < 0 ? -1 : 1)
        shakeSequence = (shakeSequence + 1) % 2
        shakeVelocity = clamped(shakeVelocity + direction * abs(strength) * displacementLimit * 5,
                                -displacementLimit * 12, displacementLimit * 12)
        boat.velocityY = max(-displacementLimit * 8, boat.velocityY - abs(strength) * displacementLimit * 1.6)
        boat.angularVelocity = clamped(boat.angularVelocity + direction * abs(strength) * 1.4, -4, 4)
        boundBoat()
    }

    /// Freeze on the current wave, with no delayed impulse waiting to resume.
    func settle() {
        shakeHeight = 0; shakeVelocity = 0
        boat.velocityX = 0; boat.velocityY = 0
        boat.angle = 0; boat.angularVelocity = 0
        guard hasArea else { boat = PaperweightBoat(x: 0, y: 0); return }
        boat.x = cruiseX()
        boundBoat(pinToSurface: true)
    }

    func surface(at x: Double) -> Double {
        guard hasArea else { return 0 }
        let x = x.isFinite ? x : Double(size.width) * 0.5
        let wavelength = max(1, Double(shipSize.width) * 2.8, Double(size.width) * 0.38)
        let position = x.truncatingRemainder(dividingBy: wavelength) / wavelength * 2 * Double.pi
        let harmonic = x.truncatingRemainder(dividingBy: wavelength / 1.8) / (wavelength / 1.8) * 2 * Double.pi
        let slosh = x.truncatingRemainder(dividingBy: wavelength / 0.75) / (wavelength / 0.75) * 2 * Double.pi
        let speed = Double(weather.seaProfile.speed)
        let amplitude = min(displacementLimit * 0.55, (compact ? 1.5 : 4) * roughness)
        let ambient = amplitude * (sin(position - time * speed)
            + 0.3 * sin(harmonic + time * speed * 0.63 + 1.1))
        let impulse = shakeHeight * sin(slosh - time * 1.2 + 0.6)
        return baseWaterline + clamped(ambient + impulse, -displacementLimit, displacementLimit)
    }

    func surfaceSlope(at x: Double) -> Double {
        let distance = max(1, Double(shipSize.width) * 0.12)
        return (surface(at: x + distance) - surface(at: x - distance)) / (distance * 2)
    }

    private var roughness: Double {
        0.5 + 2.2 * Double(weather.seaProfile.roughness)
    }

    private func updateShipSize() {
        guard hasArea else { shipSize = .zero; return }
        let roll = PaperweightConstants.maximumRoll
        // Keep the real snapshot waterline and all allowed roll angles in view.
        let above = (2.0 / 3) * waterlineFraction
        let below = (2.0 / 3) * (1 - waterlineFraction)
        let topExtent = sin(roll) * 0.5 + cos(roll) * above
        let bottomExtent = sin(roll) * 0.5 + cos(roll) * below
        let supportLift = sin(roll) * 0.4
        let topLimit = max(0, baseWaterline - displacementLimit - padding - supportSafety) / (topExtent + supportLift)
        let bottomLimit = max(0, Double(size.height) - baseWaterline - displacementLimit - padding) / bottomExtent
        let desired = compact ? min(42, Double(size.width) * 0.52) : min(280, max(160, Double(size.width) * 0.21))
        let width = max(0, min(desired, Double(size.width) * 0.8, topLimit, bottomLimit))
        shipSize = CGSize(width: width, height: width * 2 / 3)
    }

    private func cruiseX() -> Double {
        let margin = Double(shipSize.width) * 0.7
        let progress = (time / period + 0.55).truncatingRemainder(dividingBy: 1)
        return progress * (Double(size.width) + margin * 2) - margin
    }

    private func advance(_ dt: Double) {
        time += dt
        guard hasArea else { return }
        shakeVelocity = (shakeVelocity - shakeHeight * 28 * dt) * exp(-2.2 * dt)
        shakeHeight += shakeVelocity * dt
        let limit = displacementLimit * 0.85
        if abs(shakeHeight) > limit {
            shakeHeight = clamped(shakeHeight, -limit, limit)
            shakeVelocity *= 0.3
        }
        if abs(shakeHeight) + abs(shakeVelocity) < 0.00001 { shakeHeight = 0; shakeVelocity = 0 }
        boat.x = cruiseX()
        boat.velocityX = (Double(size.width) + Double(shipSize.width) * 1.4) / period
        let targetAngle = clamped(atan(surfaceSlope(at: boat.x)),
                                  -PaperweightConstants.maximumRoll, PaperweightConstants.maximumRoll)
        boat.angularVelocity = (boat.angularVelocity + (targetAngle - boat.angle) * 90 * dt) * pow(0.88, dt * 120)
        boat.angle += boat.angularVelocity * dt
        let targetY = supportedWaterline(angle: boat.angle)
        boat.velocityY = (boat.velocityY + (targetY - boat.y) * 160 * dt) * pow(0.9, dt * 120)
        boat.y += boat.velocityY * dt
        boundBoat()
    }

    /// The highest contact across the hull supports it. Sampling just its
    /// centre could leave the bow buried under a crest during a large shake.
    private func supportedWaterline(angle: Double) -> Double {
        let halfHull = Double(shipSize.width) * 0.4
        let support = (-64...64).reduce(surface(at: boat.x)) { result, index in
            let offset = halfHull * Double(index) / 64
            let water = surface(at: boat.x + offset * cos(angle))
            return min(result, water - offset * sin(angle))
        }
        // Cover the small curvature between adjacent support samples.
        return support - supportSafety
    }

    private func boundBoat(pinToSurface: Bool = false) {
        let roll = PaperweightConstants.maximumRoll
        if !boat.angle.isFinite { boat.angle = 0; boat.angularVelocity = 0 }
        if abs(boat.angle) > roll {
            boat.angle = clamped(boat.angle, -roll, roll)
            if boat.angularVelocity * boat.angle > 0 { boat.angularVelocity = 0 }
        }
        let support = supportedWaterline(angle: boat.angle)
        let top = abs(sin(boat.angle)) * Double(shipSize.width) * 0.5
            + cos(boat.angle) * Double(shipSize.height) * waterlineFraction + padding
        let bottom = Double(size.height) - abs(sin(boat.angle)) * Double(shipSize.width) * 0.5
            - cos(boat.angle) * Double(shipSize.height) * (1 - waterlineFraction) - padding
        if !boat.y.isFinite || pinToSurface { boat.y = support }
        if boat.y > support { boat.y = support; boat.velocityY = min(0, boat.velocityY) }
        if boat.y < top { boat.y = top; boat.velocityY = max(0, boat.velocityY) }
        if boat.y > bottom { boat.y = bottom; boat.velocityY = min(0, boat.velocityY) }
    }

    private func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
