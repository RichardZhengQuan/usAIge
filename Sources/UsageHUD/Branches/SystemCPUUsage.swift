import Combine
import Darwin
import Foundation

/// An interval's share of the whole Mac's CPU time, across all cores.
struct SystemCPUUsage: Equatable, Sendable {
    let user: Double
    let system: Double
    let idle: Double

    var busy: Double { user + system }

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

/// CPU has its own lightweight clock so displaying a fresh reading never
/// triggers a process scan or redraws the rest of the dashboard.
@MainActor
final class SystemCPUMonitor: ObservableObject {
    @Published private(set) var usage: SystemCPUUsage?
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
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self else { return }
                self.sample()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        previous = nil
        if usage != nil { usage = nil }
    }

    func sample() {
        let current = read()
        let reading = previous.flatMap { previous in current?.usage(since: previous) }
        previous = current
        if reading != usage { usage = reading }
    }
}
