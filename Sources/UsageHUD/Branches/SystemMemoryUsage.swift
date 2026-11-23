import Darwin
import Foundation

struct SystemMemoryUsage: Equatable, Sendable {
    /// Installed physical RAM and the portion in use, excluding swap.
    let capacityBytes: Int64
    let usedBytes: Int64
    /// Memory macOS has moved out to disk, and the swap it has set aside.
    let swapUsedBytes: Int64
    let swapTotalBytes: Int64

    var combinedCapacityBytes: Int64 { Int64(clamping: UInt64(capacityBytes) + UInt64(swapTotalBytes)) }
    var combinedUsedBytes: Int64 { Int64(clamping: UInt64(usedBytes) + UInt64(swapUsedBytes)) }
    var availableBytes: Int64 { combinedCapacityBytes - combinedUsedBytes }
    var usedShare: Double? {
        guard combinedCapacityBytes > 0 else { return nil }
        return Double(combinedUsedBytes) / Double(combinedCapacityBytes)
    }

    init(capacityBytes: Int64, usedBytes: Int64, swapUsedBytes: Int64 = 0, swapTotalBytes: Int64 = 0) {
        self.capacityBytes = max(0, capacityBytes)
        self.usedBytes = min(self.capacityBytes, max(0, usedBytes))
        self.swapUsedBytes = max(0, swapUsedBytes)
        self.swapTotalBytes = max(self.swapUsedBytes, swapTotalBytes)
    }

    init(capacityBytes: Int64, pageSize: Int64, statistics: vm_statistics64_data_t,
         swapUsedBytes: Int64 = 0, swapTotalBytes: Int64 = 0) {
        // Count non-purgeable anonymous pages, wired pages, and physical
        // compressor pages. File cache and compressed data on disk are excluded.
        let appPages = max(0, Int64(statistics.internal_page_count) - Int64(statistics.purgeable_count))
        let usedPages = appPages + Int64(statistics.wire_count) + Int64(statistics.compressor_page_count)
        self.init(capacityBytes: capacityBytes, usedBytes: usedPages * pageSize,
                  swapUsedBytes: swapUsedBytes, swapTotalBytes: swapTotalBytes)
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
        guard result == KERN_SUCCESS, let swap = readSwap() else { return nil }
        return Self(capacityBytes: capacity, pageSize: Int64(pageSize), statistics: statistics,
                    swapUsedBytes: swap.used, swapTotalBytes: swap.total)
    }

    /// Swap as Activity Monitor reports it, from `vm.swapusage`.
    private static func readSwap() -> (used: Int64, total: Int64)? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return nil }
        return (Int64(clamping: swap.xsu_used), Int64(clamping: swap.xsu_total))
    }
}

extension SystemMemoryUsage {
    private func amount(_ bytes: Int64) -> String {
        bytes == 0 ? "0 B" : LiveWorkText.memory(UInt64(bytes))
    }

    var compactTotal: String { "\(amount(combinedUsedBytes)) / \(amount(combinedCapacityBytes))" }
    var ramDescription: String { "\(amount(usedBytes)) of \(amount(capacityBytes))" }
    var swapDescription: String { "\(amount(swapUsedBytes)) of \(amount(swapTotalBytes))" }
}
