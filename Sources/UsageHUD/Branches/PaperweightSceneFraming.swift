import Foundation
import simd

/// Fits the actual perspective bounds, independently of SceneKit or a graphics device.
enum PaperweightSceneFraming {
    struct Placement {
        let front: SIMD3<Double>
        let rear: SIMD3<Double>
    }

    struct Frame {
        let target: SIMD3<Double>
        let distance: Double
    }

    // Include the bevel, fluid tilt and a little room for the floor shadow.
    static let glassCorners: [SIMD3<Double>] = [-2.2, 2.2].flatMap { x in
        [-1.12, 1.22].flatMap { y in
            [-0.72, 0.72].map { z in SIMD3(x, y, z) }
        }
    }

    static func placement(aspect: Double) -> Placement {
        // A shallow, wide window benefits from two nearly adjacent objects.
        // Taller windows retain the overlapping front/rear composition.
        let amount = min(1, max(0, (aspect - 1.4) / 1.8))
        return Placement(front: SIMD3(-0.4 - 1.9 * amount, 1.01, 0.8),
                         rear: SIMD3(1.2 + 1.2 * amount, 1.01, -3.6 + 2.7 * amount))
    }

    static func fit(points: [SIMD3<Double>], aspect: Double, yaw: Double, pitch: Double,
                    margin: Double = 1.045) -> Frame {
        guard !points.isEmpty else { return Frame(target: SIMD3(0, 1, 0), distance: 8) }
        let basis = basis(yaw: yaw, pitch: pitch)
        let vertical = tan(15 * Double.pi / 180) / margin
        let horizontal = vertical * max(0.1, aspect)
        var positiveX = -Double.infinity, negativeX = -Double.infinity
        var positiveY = -Double.infinity, negativeY = -Double.infinity
        var near = -Double.infinity, far = Double.infinity
        for point in points {
            let x = simd_dot(point, basis.right), y = simd_dot(point, basis.up)
            let z = simd_dot(point, basis.direction)
            positiveX = max(positiveX, z + x / horizontal)
            negativeX = max(negativeX, z - x / horizontal)
            positiveY = max(positiveY, z + y / vertical)
            negativeY = max(negativeY, z - y / vertical)
            near = max(near, z); far = min(far, z)
        }
        let x = (positiveX - negativeX) * horizontal / 2
        let y = (positiveY - negativeY) * vertical / 2
        let z = (near + far) / 2
        let distance = max((positiveX + negativeX) / 2, (positiveY + negativeY) / 2, near + 0.3) - z
        return Frame(target: basis.right * x + basis.up * y + basis.direction * z, distance: max(0.5, distance))
    }

    static func distance(points: [SIMD3<Double>], target: SIMD3<Double>, aspect: Double,
                         yaw: Double, pitch: Double, margin: Double) -> Double {
        let basis = basis(yaw: yaw, pitch: pitch)
        let vertical = tan(15 * Double.pi / 180) / margin
        let horizontal = vertical * max(0.1, aspect)
        return points.reduce(0.5) { result, point in
            let offset = point - target
            let along = simd_dot(offset, basis.direction)
            return max(result, along + abs(simd_dot(offset, basis.right)) / horizontal,
                       along + abs(simd_dot(offset, basis.up)) / vertical, along + 0.3)
        }
    }

    private static func basis(yaw: Double, pitch: Double) -> (right: SIMD3<Double>, up: SIMD3<Double>, direction: SIMD3<Double>) {
        (SIMD3(cos(yaw), 0, -sin(yaw)),
         SIMD3(-sin(yaw) * sin(pitch), cos(pitch), -cos(yaw) * sin(pitch)),
         SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)))
    }
}
