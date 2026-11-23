import Foundation
import Testing
@testable import UsageHUD

@Suite struct SystemCPUUsageTests {
    @Test func cpuActivityStatusUsesTheRecordedIntervalAndInclusiveThresholds() {
        func status(_ busy: Double) -> TrendStatus {
            SystemCPUUsage(user: busy, system: 0, idle: 1 - busy).trendStatus
        }
        #expect(status(0) == .normal)
        #expect(status(0.699) == .normal)
        #expect(status(0.7) == .warning)
        #expect(status(0.899) == .warning)
        #expect(status(0.9) == .critical)
        #expect(status(1) == .critical)
        #expect(status(.nan) == .unknown)
    }

    @Test func chartColorsEachRecordedIntervalAndLeavesMissingDataOpen() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let statuses: [TrendStatus?] = [.normal, .normal, .warning, .critical, nil, nil, .normal, .normal]
        let points = statuses.enumerated().map { index, status in
            TrendPoint(date: start.addingTimeInterval(Double(index)), value: index == 4 ? nil : 0.5, status: status)
        }
        let runs = TrendSegment.make(from: points, in: start...points[6].date)
        #expect(runs.map(\.status) == [.normal, .warning, .critical, .unknown, .normal])
        #expect(runs.map { $0.points.map(\.date) } == [[0, 1], [1, 2], [2, 3], [5], [5, 6]].map { group in
            group.map { start.addingTimeInterval(Double($0)) }
        })
        #expect(runs.map(\.marksEndpoint) == [false, false, true, false, true])
    }

    @Test func usesAllHostTickDeltasIncludingNiceTimeAndCounterRollover() throws {
        let first = SystemCPUUsage.Ticks(user: UInt32.max - 9, system: 20, idle: 90, nice: 1)
        let last = SystemCPUUsage.Ticks(user: 10, system: 45, idle: 140, nice: 6)
        let usage = try #require(last.usage(since: first))
        #expect(usage.user == 0.25)
        #expect(usage.system == 0.25)
        #expect(usage.idle == 0.5)
        #expect(usage.busy == 0.5)
        #expect(last.usage(since: last) == nil)
    }

    @MainActor
    @Test func firstFailedAndStoppedSamplesDoNotShowInventedUtilization() {
        let first = SystemCPUUsage.Ticks(user: 0, system: 0, idle: 0, nice: 0)
        let idle = SystemCPUUsage.Ticks(user: 0, system: 0, idle: 20, nice: 0)
        let busy = SystemCPUUsage.Ticks(user: 10, system: 10, idle: 20, nice: 0)
        var readings: [SystemCPUUsage.Ticks?] = [first, idle, nil, idle, busy]
        let monitor = SystemCPUMonitor(read: { readings.removeFirst() })
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        monitor.sample(at: start)
        #expect(monitor.usage == nil)
        monitor.sample(at: start.addingTimeInterval(2))
        #expect(monitor.usage?.busy == 0)
        monitor.sample(at: start.addingTimeInterval(4))
        #expect(monitor.usage == nil)
        monitor.sample(at: start.addingTimeInterval(6))
        #expect(monitor.usage == nil)
        monitor.sample(at: start.addingTimeInterval(8))
        #expect(monitor.usage?.busy == 1)
        #expect(monitor.samples.map { $0.usage?.busy } == [nil, 0, nil, nil, 1])
        monitor.stop()
        #expect(monitor.usage == nil)
        #expect(monitor.samples.isEmpty)
    }

    @MainActor
    @Test func hourlyHistoryKeepsEqualReadingsAndSelectsRealSamplesForEveryRangeAfterWrapping() {
        var count: UInt32 = 0
        let monitor = SystemCPUMonitor {
            count += 10
            return .init(user: count, system: 0, idle: count, nice: 0)
        }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for second in stride(from: 0, through: 7_200, by: 2) {
            monitor.sample(at: start.addingTimeInterval(Double(second)))
        }
        let end = start.addingTimeInterval(7_200)
        #expect(SystemTrendRange.standard == .fiveMinutes)
        #expect(SystemTrendRange.allCases.map(\.minutes) == [1, 5, 15, 60])
        #expect(monitor.samples.count == 1_801)
        #expect(monitor.samples.first?.date == start.addingTimeInterval(3_600))
        #expect(monitor.samples.allSatisfy { $0.usage?.busy == 0.5 })
        for range in SystemTrendRange.allCases {
            let visible = monitor.samples.window(for: range)
            #expect(visible.count == range.minutes * 30 + 1)
            #expect(visible.first?.date == end.addingTimeInterval(-range.duration))
            #expect(visible.last?.date == end)
            #expect(monitor.samples.domain(for: range) == end.addingTimeInterval(-range.duration)...end)
        }
        monitor.sample(at: end.addingTimeInterval(10))
        #expect(monitor.usage == nil)
        #expect(monitor.samples.first?.date == start.addingTimeInterval(3_610))
        monitor.sample(at: end.addingTimeInterval(12))
        #expect(monitor.usage?.busy == 0.5)
        #expect(monitor.samples.window(for: .oneMinute).suffix(2).map { $0.usage?.busy } == [nil, 0.5])
        monitor.sample(at: start)
        #expect(monitor.samples.count == 1)
        #expect(monitor.usage == nil)
    }

    @MainActor
    @Test func chartGrowsFromTheFirstObservationAndDiscardsExpiredSamplesAfterSleep() {
        var tick: UInt32 = 0
        let monitor = SystemCPUMonitor {
            tick += 1
            return .init(user: tick, system: 0, idle: tick, nice: 0)
        }
        let start = Date(timeIntervalSinceReferenceDate: 100)
        for second in stride(from: 0, through: 40, by: 2) {
            monitor.sample(at: start.addingTimeInterval(Double(second)))
        }
        for range in SystemTrendRange.allCases {
            #expect(monitor.samples.domain(for: range) == start...start.addingTimeInterval(40))
            #expect(monitor.samples.window(for: range).count == 21)
        }
        let wake = start.addingTimeInterval(10_000)
        monitor.sample(at: wake)
        #expect(monitor.usage == nil)
        #expect(monitor.samples.count == 1)
        #expect(monitor.samples.first?.date == wake)
        monitor.sample(at: wake.addingTimeInterval(2))
        #expect(monitor.usage?.busy == 0.5)
    }

    @Test func processEstimatesCannotConsumeSwapTwice() {
        let process = WorkProcess(id: 1, name: "tool", folder: "/work", memoryBytes: 900, startedAt: nil, ports: [])
        let summary = LiveWorkSummary(appProcesses: [.claude: [process]])
        let memory = SystemMemoryUsage(capacityBytes: 1_000, usedBytes: 600, swapUsedBytes: 200, swapTotalBytes: 500)
        let chart = PaperweightData.memory(summary: summary, running: [], systemUsage: memory)
        #expect(chart.allocationIsEstimated)
        #expect(chart.layers.first { $0.id == "tool-claude" }?.bytes == 600)
        #expect(chart.layers.first { $0.id == PaperweightData.swapLayerID }?.bytes == 200)
        #expect(chart.usedBytes == memory.combinedUsedBytes)
        #expect(chart.freeBytes == 700)
        #expect(chart.usedShare == memory.usedShare)
    }
}
