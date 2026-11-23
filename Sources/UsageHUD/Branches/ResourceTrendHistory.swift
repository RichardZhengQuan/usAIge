import Combine
import Foundation

/// Retains real byte readings independently of the more expensive process scan UI.
@MainActor
final class ResourceTrendHistory: ObservableObject {
    @Published private(set) var samples: [TrendPoint] = []
    private let interval: TimeInterval

    var domain: ClosedRange<Date> { SystemTrendWindow.ending(at: samples.last?.date ?? Date()) }

    init(interval: TimeInterval) { self.interval = interval }

    func record(bytes: Int64?, status: TrendStatus = .unknown, at date: Date) {
        let cutoff = SystemTrendWindow.ending(at: date).lowerBound
        var recent = samples
        if let last = recent.last, date < last.date { recent.removeAll() }
        recent.removeFirst(recent.prefix { $0.date < cutoff }.count)
        // Repeated refreshes in the same second describe one observation.
        if let last = recent.last,
           floor(last.date.timeIntervalSinceReferenceDate) == floor(date.timeIntervalSinceReferenceDate) {
            recent.removeLast()
        }
        if let last = recent.last, last.value != nil, date.timeIntervalSince(last.date) > 2.5 * interval {
            recent.append(TrendPoint(date: last.date.addingTimeInterval(interval), value: nil))
        }
        let value = bytes.flatMap { $0 >= 0 ? Double($0) : nil }
        recent.append(TrendPoint(date: date, value: value, status: value == nil ? nil : status))
        samples = recent
    }
}

extension SystemMemoryPressure {
    var trendStatus: TrendStatus {
        switch self {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        case .unknown: .unknown
        }
    }
}

extension TrendStatus {
    static func storage(usedShare: Double) -> Self {
        guard (0...1).contains(usedShare) else { return .unknown }
        if usedShare >= 0.95 { return .critical }
        if usedShare >= 0.90 { return .warning }
        return .normal
    }
}
