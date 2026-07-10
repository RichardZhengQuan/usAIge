import CoreGraphics
import Foundation
import Observation

struct HideTriggers: Codable, Equatable, Sendable {
    var fullScreenApps: Bool
    var fullScreenVideo: Bool
    var games: Bool
    var presentations: Bool
    var screenSharing: Bool

    static let allEnabled = Self(
        fullScreenApps: true,
        fullScreenVideo: true,
        games: true,
        presentations: true,
        screenSharing: true
    )
}

struct HUDPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

@MainActor
@Observable
final class HUDSettings {
    private struct Payload: Codable, Equatable {
        var version = 1
        var bucketOrder: [String] = []
        var hiddenBucketIDs: Set<String> = []
        var scale = 1.0
        var opacity = 0.92
        var positions: [String: HUDPosition] = [:]
        var hideTriggers = HideTriggers.allEnabled
    }

    private static let storageKey = "usageHUD.settings.v1"
    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.version == 1 {
            payload = decoded
        } else {
            payload = Payload()
        }
        payload.scale = Self.clamp(payload.scale, to: 0.75...1.5)
        payload.opacity = Self.clamp(payload.opacity, to: 0.4...1.0)
    }

    var bucketOrder: [String] {
        get { payload.bucketOrder }
        set { payload.bucketOrder = newValue; persist() }
    }

    var hiddenBucketIDs: Set<String> {
        get { payload.hiddenBucketIDs }
        set { payload.hiddenBucketIDs = newValue; persist() }
    }

    var scale: Double {
        get { payload.scale }
        set { payload.scale = Self.clamp(newValue, to: 0.75...1.5); persist() }
    }

    var opacity: Double {
        get { payload.opacity }
        set { payload.opacity = Self.clamp(newValue, to: 0.4...1.0); persist() }
    }

    var hideTriggers: HideTriggers {
        get { payload.hideTriggers }
        set { payload.hideTriggers = newValue; persist() }
    }

    func ordered(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let order = Dictionary(uniqueKeysWithValues: bucketOrder.enumerated().map { ($1, $0) })
        return snapshots
            .filter { !hiddenBucketIDs.contains($0.id) }
            .sorted { lhs, rhs in
                switch (order[lhs.id], order[rhs.id]) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.id < rhs.id
                }
            }
    }

    func setPosition(_ point: CGPoint, for displayKey: String) {
        payload.positions[displayKey] = HUDPosition(point)
        persist()
    }

    func position(for displayKey: String) -> CGPoint? {
        payload.positions[displayKey]?.point
    }

    func resetPosition(for displayKey: String) {
        payload.positions.removeValue(forKey: displayKey)
        persist()
    }

    func moveBucket(_ id: String, by offset: Int) {
        var order = bucketOrder
        guard let index = order.firstIndex(of: id) else { return }
        let destination = min(max(0, index + offset), order.count - 1)
        guard destination != index else { return }
        order.swapAt(index, destination)
        bucketOrder = order
    }

    func registerBuckets(_ ids: [String]) {
        let additions = ids.filter { !bucketOrder.contains($0) }
        guard !additions.isEmpty else { return }
        bucketOrder.append(contentsOf: additions)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
