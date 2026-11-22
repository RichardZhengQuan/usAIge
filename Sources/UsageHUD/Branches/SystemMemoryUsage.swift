import Darwin
import Foundation

struct SystemMemoryUsage: Equatable, Sendable {
    let capacityBytes: Int64
    let usedBytes: Int64

    var availableBytes: Int64 { capacityBytes - usedBytes }

    init(capacityBytes: Int64, usedBytes: Int64) {
        self.capacityBytes = max(0, capacityBytes)
        self.usedBytes = min(self.capacityBytes, max(0, usedBytes))
    }

    init(capacityBytes: Int64, pageSize: Int64, statistics: vm_statistics64_data_t) {
        // Count non-purgeable anonymous pages, wired pages, and physical
        // compressor pages. File cache and compressed data on disk are excluded.
        let appPages = max(0, Int64(statistics.internal_page_count) - Int64(statistics.purgeable_count))
        let usedPages = appPages + Int64(statistics.wire_count) + Int64(statistics.compressor_page_count)
        self.init(capacityBytes: capacityBytes, usedBytes: usedPages * pageSize)
    }

    static func read() -> Self? {
        let capacity = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        guard capacity > 0 else { return nil }

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var statistics = vm_statistics64_data_t()
        let capacityInWords = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacityInWords)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacityInWords) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Self(capacityBytes: capacity, pageSize: Int64(pageSize), statistics: statistics)
    }
}
