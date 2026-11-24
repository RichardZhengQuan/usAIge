import AppKit
import SwiftUI
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
        let expectedTimes = [[0, 1], [1, 2], [2, 3], [5], [5, 6]].map { offsets in
            offsets.map { start.addingTimeInterval(Double($0)) }
        }
        #expect(runs.map(\.status) == [.normal, .warning, .critical, .unknown, .normal])
        #expect(runs.map { $0.points.map(\.date) } == expectedTimes)
        #expect(runs.map(\.marksEndpoint) == [false, false, true, false, true])
    }

    @Test func everyChartKeepsTenMinutesOfHistoryAtTheSameScaleAsSamplesArrive() {
        let end = Date(timeIntervalSinceReferenceDate: 1_000)
        let domain = SystemTrendWindow.ending(at: end)
        #expect(domain.lowerBound == end.addingTimeInterval(-600))
        let next = SystemTrendWindow.ending(at: end.addingTimeInterval(30))
        for (width, inset): (CGFloat, CGFloat) in [(22, 1.5), (39, 1.5), (165, 1.5), (540, 3), (1_100, 3)] {
            let first = TrendTimeScale(domain: domain, width: width, inset: inset)
            let second = TrendTimeScale(domain: next, width: width, inset: inset)
            let span = (width - 2 * inset) * 0.60
            #expect(abs(first.x(at: domain.lowerBound) - inset) < 0.001)
            #expect(abs(first.x(at: end) - inset - span) < 0.001)
            #expect(second.x(at: next.upperBound) == first.nowX)
            for offset in [-550.0, -190, -30, 0] {
                let measured = end.addingTimeInterval(offset)
                #expect(abs(first.x(at: measured) - second.x(at: measured) - span * 30 / 600) < 0.001)
            }
        }
    }

    @MainActor
    @Test func fullSizeChartDrawsItsLatestTickUnderTheLiveDotAndLeavesTheRightMarginOpen() throws {
        guard #available(macOS 13.0, *) else { return }
        let start = Date(timeIntervalSinceReferenceDate: 1_000), end = start.addingTimeInterval(600)
        let points = [start, end].map { TrendPoint(date: $0, value: 0.5, status: .normal) }
            + [TrendPoint(date: end.addingTimeInterval(10), value: 0.9, status: .critical)]
        let width = 320, plotHeight = 80
        let chart = TrendHistoryPlot(points: points, domain: start...end, valueRange: 0...1,
                                     plotHeight: CGFloat(plotHeight)) { EmptyView() }
            .frame(width: CGFloat(width))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        let nowX = TrendTimeScale(domain: start...end, width: CGFloat(width)).nowX * renderer.scale
        let plotBottom = plotHeight * 2
        // At two points above the flat line, only the endpoint disk is opaque.
        let dotPixels = (0..<bitmap.pixelsWide).filter { alpha($0, plotHeight - 4) > 0.9 }
        let left = try #require(dotPixels.first), right = try #require(dotPixels.last)
        #expect(abs(CGFloat(left + right + 1) / 2 - nowX) <= 1)
        let tickPixels = (width..<bitmap.pixelsWide).filter { alpha($0, plotBottom + 8) > 0.1 }
        #expect(!tickPixels.isEmpty && tickPixels.allSatisfy { abs(CGFloat($0) + 0.5 - nowX) <= 1 })
        let margin = Int(ceil(nowX)) + 6..<bitmap.pixelsWide
        #expect(margin.allSatisfy { x in (0..<plotBottom).allSatisfy { alpha(x, $0) < 0.9 } })
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
    @Test func tenMinuteHistoryRetainsEqualReadingsAndEvictsExpiredSamplesAfterWrapping() {
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
        #expect(monitor.samples.count == 301)
        #expect(monitor.samples.first?.date == start.addingTimeInterval(6_600))
        #expect(monitor.samples.last?.date == end)
        #expect(monitor.samples.allSatisfy { $0.usage?.busy == 0.5 })
        #expect(monitor.samples.domain == end.addingTimeInterval(-600)...end)
        monitor.sample(at: end.addingTimeInterval(10))
        #expect(monitor.usage == nil)
        #expect(monitor.samples.first?.date == start.addingTimeInterval(6_610))
        monitor.sample(at: end.addingTimeInterval(12))
        #expect(monitor.usage?.busy == 0.5)
        #expect(monitor.samples.suffix(2).map { $0.usage?.busy } == [nil, 0.5])
        monitor.sample(at: start)
        #expect(monitor.samples.count == 1)
        #expect(monitor.usage == nil)
    }

    @MainActor
    @Test func chartKeepsTheFullTimeWindowDuringWarmupAndAfterSleep() {
        var tick: UInt32 = 0
        let monitor = SystemCPUMonitor {
            tick += 1
            return .init(user: tick, system: 0, idle: tick, nice: 0)
        }
        let start = Date(timeIntervalSinceReferenceDate: 100)
        for second in stride(from: 0, through: 40, by: 2) {
            monitor.sample(at: start.addingTimeInterval(Double(second)))
        }
        #expect(monitor.samples.domain == start.addingTimeInterval(-560)...start.addingTimeInterval(40))
        #expect(monitor.samples.count == 21)
        #expect(monitor.samples.first?.date == start)
        let wake = start.addingTimeInterval(10_000)
        monitor.sample(at: wake)
        #expect(monitor.usage == nil)
        #expect(monitor.samples.count == 1)
        #expect(monitor.samples.first?.date == wake)
        #expect(monitor.samples.domain == wake.addingTimeInterval(-600)...wake)
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
