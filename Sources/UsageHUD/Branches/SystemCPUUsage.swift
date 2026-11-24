import Combine
import Darwin
import Foundation

/// An interval's share of the whole Mac's CPU time, across all cores.
struct SystemCPUUsage: Equatable, Sendable {
    let user: Double
    let system: Double
    let idle: Double

    var busy: Double { user + system }

    /// Whole-Mac CPU occupancy, expressed as a fraction across all cores.
    var trendStatus: TrendStatus {
        guard busy.isFinite, busy >= 0 else { return .unknown }
        if busy >= 0.9 { return .critical }
        if busy >= 0.7 { return .warning }
        return .normal
    }

    struct Ticks: Sendable {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32

        func usage(since previous: Self) -> SystemCPUUsage? {
            // Each Mach counter is 32-bit and can wrap while the app is open.
            let userTime = UInt64(user &- previous.user) + UInt64(nice &- previous.nice)
            let systemTime = UInt64(system &- previous.system)
            let idleTime = UInt64(idle &- previous.idle)
            let total = Double(userTime + systemTime + idleTime)
            guard total > 0 else { return nil }
            return SystemCPUUsage(user: Double(userTime) / total, system: Double(systemTime) / total,
                                  idle: Double(idleTime) / total)
        }

        static func read() -> Self? {
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            var info = host_cpu_load_info_data_t()
            let words = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
            var count = mach_msg_type_number_t(words)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                    host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS, Int(count) == words else { return nil }
            return withUnsafeBytes(of: info.cpu_ticks) { buffer in
                let ticks = buffer.bindMemory(to: natural_t.self)
                return Self(user: ticks[Int(CPU_STATE_USER)], system: ticks[Int(CPU_STATE_SYSTEM)],
                            idle: ticks[Int(CPU_STATE_IDLE)], nice: ticks[Int(CPU_STATE_NICE)])
            }
        }
    }
}

enum SystemTrendWindow {
    static let duration: TimeInterval = 10 * 60

    static func ending(at date: Date) -> ClosedRange<Date> {
        date.addingTimeInterval(-duration)...date
    }
}

/// CPU has its own lightweight clock so displaying a fresh reading never
/// triggers a process scan or redraws the rest of the dashboard.
@MainActor
final class SystemCPUMonitor: ObservableObject {
    struct Sample {
        let date: Date
        let usage: SystemCPUUsage?
    }

    nonisolated static let sampleInterval: TimeInterval = 2

    /// Chronological access to a bounded ring, including explicit gaps.
    struct History: RandomAccessCollection {
        private static let capacity = Int(SystemTrendWindow.duration / SystemCPUMonitor.sampleInterval) + 1
        private var storage: [Sample] = []
        private var head = 0
        private(set) var count = 0

        var startIndex: Int { 0 }
        var endIndex: Int { count }
        subscript(index: Int) -> Sample { storage[(head + index) % Self.capacity] }

        fileprivate mutating func append(_ sample: Sample) {
            if let last, sample.date <= last.date { self = Self() }
            let cutoff = sample.date.addingTimeInterval(-SystemTrendWindow.duration)
            while let first, count == Self.capacity || first.date < cutoff {
                head = (head + 1) % Self.capacity
                count -= 1
            }
            let slot = (head + count) % Self.capacity
            if slot < storage.count { storage[slot] = sample } else { storage.append(sample) }
            count += 1
        }

        var domain: ClosedRange<Date> { SystemTrendWindow.ending(at: last?.date ?? Date()) }
    }

    @Published private(set) var usage: SystemCPUUsage?
    private(set) var samples = History()
    private var previous: SystemCPUUsage.Ticks?
    private var loop: Task<Void, Never>?
    private let read: () -> SystemCPUUsage.Ticks?

    init(read: @escaping () -> SystemCPUUsage.Ticks? = SystemCPUUsage.Ticks.read) {
        self.read = read
    }

    func start() {
        guard loop == nil else { return }
        sample()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(Self.sampleInterval * 1_000_000_000)) } catch { return }
                guard let self else { return }
                self.sample()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        previous = nil
        samples = History()
        usage = nil
    }

    func sample(at date: Date = Date()) {
        let current = read()
        let elapsed = samples.last.map { date.timeIntervalSince($0.date) } ?? 0
        // A late tick after sleep or a changed clock starts a fresh interval.
        let consecutive = elapsed > 0 && elapsed <= Self.sampleInterval * 2
        let reading = consecutive ? previous.flatMap { current?.usage(since: $0) } : nil
        previous = current
        samples.append(Sample(date: date, usage: reading))
        // Publish every interval, including a repeated value on a flat chart.
        usage = reading
    }
}
