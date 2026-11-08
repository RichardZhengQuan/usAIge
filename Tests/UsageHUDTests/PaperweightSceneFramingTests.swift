import Foundation
import simd
import Testing
@testable import UsageHUD

@Suite struct PaperweightSceneFramingTests {
    @Test func defaultViewFitsBothPaperweightsWithoutWideEmptyMargins() {
        for aspect in [1.2, 1.6, 2.0, 2.5, 3.0, 3.6, 4.0] {
            let yaw = atan2(-0.6, 8.6), pitch = atan2(2.5, hypot(0.6, 8.6))
            let placement = PaperweightSceneFraming.placement(aspect: aspect)
            let points = transformedCorners(at: placement.front, yaw: 0.07)
                + transformedCorners(at: placement.rear, yaw: -0.34)
            let frame = PaperweightSceneFraming.fit(points: points, aspect: aspect, yaw: yaw, pitch: pitch)
            let projected = project(points, frame: frame, aspect: aspect, yaw: yaw, pitch: pitch)
            #expect(projected.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
            let width = projected.map(\.x).max()! - projected.map(\.x).min()!
            let height = projected.map(\.y).max()! - projected.map(\.y).min()!
            #expect(max(width, height) > 1.85)
            if aspect >= 2 && aspect <= 3.6 { #expect(width > 1.65) }
        }
    }

    @Test func rotatedAndLiftedPaperweightsStayInsideTheDefaultFit() {
        for yaw in [-0.6, 0.0, 0.6] {
            for pitch in [0.14, 0.3, 0.73] {
                let placement = PaperweightSceneFraming.placement(aspect: 3)
                let points = transformedCorners(at: placement.front + SIMD3(1.5, 0, -0.9), yaw: 0.07)
                    + transformedCorners(at: placement.rear + SIMD3(-1.9, 0.7, 0), yaw: -0.34)
                let frame = PaperweightSceneFraming.fit(points: points, aspect: 3, yaw: yaw, pitch: pitch)
                #expect(project(points, frame: frame, aspect: 3, yaw: yaw, pitch: pitch)
                    .allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
            }
        }
    }

    private func transformedCorners(at position: SIMD3<Double>, yaw: Double) -> [SIMD3<Double>] {
        PaperweightSceneFraming.glassCorners.map { point in
            position + SIMD3(point.x * cos(yaw) + point.z * sin(yaw), point.y,
                             -point.x * sin(yaw) + point.z * cos(yaw))
        }
    }

    private func project(_ points: [SIMD3<Double>], frame: PaperweightSceneFraming.Frame,
                         aspect: Double, yaw: Double, pitch: Double) -> [SIMD2<Double>] {
        let right = SIMD3(cos(yaw), 0, -sin(yaw))
        let up = SIMD3(-sin(yaw) * sin(pitch), cos(pitch), -cos(yaw) * sin(pitch))
        let direction = SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let tangent = tan(15 * Double.pi / 180)
        return points.map { point in
            let offset = point - frame.target
            let depth = frame.distance - simd_dot(offset, direction)
            return SIMD2(simd_dot(offset, right) / (depth * tangent * aspect),
                         simd_dot(offset, up) / (depth * tangent))
        }
    }
}
