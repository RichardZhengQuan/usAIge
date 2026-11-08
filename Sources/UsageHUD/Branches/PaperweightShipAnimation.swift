import SceneKit
import simd

/// A deterministic pose, driven by the owner's existing clock. No SCNActions,
/// physics bodies, per-part timers, or renderer-owned animation loops.
@available(macOS 14.0, *)
@MainActor
final class PaperweightShipAnimation {
    enum Part: String, CaseIterable {
        case sail, flag, propeller, rotor, wheel, oar, figurehead, radar, pulse, smoke, serpent
    }

    static let cycleDuration: TimeInterval = 4
    private static let partKey = "|usAIge.motion="
    private let parts: [Joint]
    private let phase: Double

    private struct Joint {
        let node: SCNNode
        let kind: Part
        let transform: simd_float4x4
        let position: SCNVector3
        let orientation: simd_quatf
        let scale: SCNVector3
        let opacity: CGFloat
    }

    @discardableResult
    static func tag(_ node: SCNNode, as part: Part) -> SCNNode {
        let name = node.name?.components(separatedBy: partKey).first ?? ""
        node.name = name + partKey + part.rawValue
        return node
    }

    init(ship: SCNNode, kind: PaperweightShipKind) {
        var joints: [Joint] = []
        ship.enumerateChildNodes { node, _ in
            if let joint = PaperweightShipAnimation.joint(for: node) { joints.append(joint) }
        }
        parts = joints
        // Stable across launches; adjacent masts have staggered wind phases.
        phase = Double(kind.rawValue.utf8.reduce(0) { ($0 + Int($1)) % 31 }) / 31 * 2 * .pi
    }

    private static func joint(for node: SCNNode) -> Joint? {
        guard let name = node.name, name.contains(partKey),
              let raw = name.components(separatedBy: partKey).last,
              let part = Part(rawValue: raw) else { return nil }
        return Joint(node: node, kind: part, transform: node.simdTransform,
                     position: node.position, orientation: node.simdOrientation,
                     scale: node.scale, opacity: node.opacity)
    }

    var partCount: Int { parts.count }
    var partKinds: Set<Part> { Set(parts.map(\.kind)) }

    func reset() {
        for part in parts {
            part.node.simdTransform = part.transform
            part.node.opacity = part.opacity
        }
    }

    func apply(time: TimeInterval, reduceMotion: Bool = false) {
        guard !reduceMotion, time.isFinite else { reset(); return }
        let progress = time.truncatingRemainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
        let angle = progress * 2 * .pi
        for (index, joint) in parts.enumerated() {
            let node = joint.node
            node.simdTransform = joint.transform
            node.opacity = joint.opacity
            let offset = phase + Double(index) * 0.73
            let wave = sin(angle + offset)
            func rotate(_ radians: Double, axis: SIMD3<Float>) {
                node.simdOrientation = joint.orientation * simd_quatf(angle: Float(radians), axis: axis)
            }
            switch joint.kind {
            case .sail:
                rotate(0.12 * wave, axis: [0, 1, 0])
                node.scale.z = joint.scale.z * CGFloat(1 + 0.16 * sin(angle * 2 + offset))
            case .flag:
                rotate(0.22 * sin(angle * 3 + offset), axis: [0, 1, 0])
                node.scale.x = joint.scale.x * CGFloat(1 + 0.06 * sin(angle * 3 + offset))
            case .propeller:
                rotate(angle * 2, axis: [1, 0, 0])
            case .rotor:
                rotate(angle * 2, axis: [0, 1, 0])
            case .wheel:
                rotate(-angle, axis: [0, 0, 1])
            case .oar:
                rotate(0.13 * wave, axis: [1, 0, 0])
            case .figurehead:
                rotate(0.055 * wave, axis: [0, 0, 1])
                node.position.y = joint.position.y + CGFloat(0.16 * wave)
            case .radar:
                rotate(angle, axis: [0, 1, 0])
            case .pulse:
                let amount = CGFloat(1 + 0.045 * sin(angle * 2 + offset))
                node.scale = SCNVector3(joint.scale.x * amount, joint.scale.y * amount, joint.scale.z * amount)
            case .serpent:
                rotate(0.07 * wave, axis: [0, 0, 1])
            case .smoke:
                let rise = (progress + Double(index) * 0.31).truncatingRemainder(dividingBy: 1)
                node.position.y = joint.position.y - CGFloat(2.4 * (1 - rise))
                node.position.x = joint.position.x - CGFloat(0.65 * rise)
                let amount = CGFloat(0.65 + 0.4 * rise)
                node.scale = SCNVector3(joint.scale.x * amount, joint.scale.y * amount, joint.scale.z * amount)
                node.opacity = joint.opacity * CGFloat(sin(.pi * rise))
            }
        }
    }
}
