import AppKit
import SwiftUI
import Testing
@testable import UsageHUD

@MainActor
struct ResourceTrendTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func retainsMeasuredValuesAndInterruptions() {
        let history = ResourceTrendHistory(interval: 10)
        history.record(bytes: 12, status: .normal, at: start)
        history.record(bytes: 14, status: .warning, at: start.addingTimeInterval(0.5))
        history.record(bytes: 14, status: .critical, at: start.addingTimeInterval(10))
        history.record(bytes: 16, status: .normal, at: start.addingTimeInterval(50))
        history.record(bytes: nil, at: start.addingTimeInterval(60))
        history.record(bytes: 0, at: start.addingTimeInterval(70))
        #expect(history.samples.map(\.value) == [14, 14, nil, 16, nil, 0])
        #expect(history.samples.map(\.status) == [.warning, .critical, nil, .normal, nil, .unknown])
        #expect(history.samples[2].date == start.addingTimeInterval(20))
    }

    @Test func dropsOldReadingsAndRecoversFromClockChanges() {
        let history = ResourceTrendHistory(interval: 60)
        for minute in 0...65 {
            history.record(bytes: Int64(minute), at: start.addingTimeInterval(Double(minute * 60)))
        }
        #expect(history.samples.count == 11)
        #expect(history.samples.first?.value == 55)
        let lastPoll = start.addingTimeInterval(65 * 60)
        #expect(history.domain == lastPoll.addingTimeInterval(-600)...lastPoll)
        history.record(bytes: 9, at: start)
        #expect(history.samples == [TrendPoint(date: start, value: 9, status: .unknown)])
    }

    @Test func compactResourceCardsAnchorTheEntireTraceToTheLatestPoll() throws {
        guard #available(macOS 14.0, *) else { return }
        let history = ResourceTrendHistory(interval: 60)
        for minute in 0...5 {
            history.record(bytes: 8_000_000, status: .normal, at: start.addingTimeInterval(Double(minute * 60)))
        }
        for resource in [PaperweightID.memory, .storage] {
            let chart = ResourceTrendChart(history: history, resource: resource, compact: true)
                .frame(width: 200)
            let renderer = ImageRenderer(content: chart)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // Only five minutes have been measured. They occupy the second
            // half of the ten-minute history, between 30% and 60% of the plot.
            let drawn = (0..<bitmap.pixelsWide).filter { x in
                (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 }
            }
            let left = try #require(drawn.first), right = try #require(drawn.last)
            let firstPoint = (CGFloat(left) + 0.5) / renderer.scale
            let lastPoint = (CGFloat(right) + 0.5) / renderer.scale
            #expect(abs(firstPoint - 60.6) <= 1)
            #expect(abs(lastPoint - 119.7) <= 1.5)
        }
    }

    @Test func respectsStorageAndNativeMemoryPressureBoundaries() {
        #expect(TrendStatus.storage(usedShare: 0.89) == .normal)
        #expect(TrendStatus.storage(usedShare: 0.90) == .warning)
        #expect(TrendStatus.storage(usedShare: 0.95) == .critical)
        #expect(TrendStatus.storage(usedShare: .nan) == .unknown)
        #expect(SystemMemoryPressure.warning.trendStatus == .warning)
        #expect(SystemMemoryPressure.critical.trendStatus == .critical)
        #expect(SystemMemoryPressure.unknown.trendStatus == .unknown)
    }

    @Test func gridUsesTheLatestVisibleStatusAndLargeSquareCells() {
        let points = [
            TrendPoint(date: start, value: 40, status: .normal),
            TrendPoint(date: start.addingTimeInterval(10), value: 92, status: .critical),
            TrendPoint(date: start.addingTimeInterval(20), value: nil, status: nil),
        ]
        #expect(TrendPoint.currentStatus(in: points, domain: start...start) == .normal)
        #expect(TrendPoint.currentStatus(in: points, domain: start...start.addingTimeInterval(15)) == .critical)
        #expect(TrendPoint.currentStatus(in: points, domain: start...start.addingTimeInterval(30)) == .unknown)
        #expect(TrendPoint.currentStatus(in: [], domain: start...start) == .unknown)
        #expect(TrendPlotGrid.cellSide(for: CGSize(width: 540, height: 120), compact: false) == 60)
        #expect(TrendPlotGrid.cellSide(for: CGSize(width: 100, height: 32), compact: true) == 20)
        #expect(TrendPlotGrid.cellSide(for: CGSize(width: 30, height: 15), compact: true) == 10)
    }

    @Test func chartBackdropReachesTransparencyAtEveryEdgeAndPreservesTheTrace() throws {
        guard #available(macOS 13.0, *) else { return }
        let size = CGSize(width: 240, height: 96)
        let area = Path(CGRect(origin: .zero, size: size))
        let backdrop = TrendPlotGrid(compact: false, status: .critical, areas: [.critical: area])
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let backdropImage = try #require(ImageRenderer(content: backdrop).cgImage)
        let bitmap = NSBitmapImageRep(cgImage: backdropImage)
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1
        }
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        #expect((0..<width).allSatisfy { alpha($0, 0) == 0 && alpha($0, height - 1) == 0 })
        #expect((0..<height).allSatisfy { alpha(0, $0) == 0 && alpha(width - 1, $0) == 0 })
        #expect(alpha(width / 2, height / 2) > 0.1)

        let end = start.addingTimeInterval(60)
        let points = [start, end].map { TrendPoint(date: $0, value: 0.5, status: .normal) }
        let plot = TrendLinePlot(points: points, domain: start...end, valueRange: 0...1)
            .frame(width: size.width, height: size.height)
        let plotImage = try #require(ImageRenderer(content: plot).cgImage)
        let trace = NSBitmapImageRep(cgImage: plotImage)
        #expect((trace.colorAt(x: 3, y: height / 2)?.alphaComponent ?? 0) > 0.9)
        let latestX = Int(TrendTimeScale(domain: start...end, width: size.width).nowX.rounded())
        #expect((trace.colorAt(x: latestX, y: height / 2)?.alphaComponent ?? 0) > 0.9)
        #expect((trace.colorAt(x: width - 3, y: height / 2)?.alphaComponent ?? 1) == 0)
    }

    @Test func usesRAMAndSwapForMemoryAndAvailableBytesForDisk() async {
        let memory = SystemMemoryUsage(capacityBytes: 1000, usedBytes: 400, swapUsedBytes: 30, swapTotalBytes: 50)
        let disk = DiskSpace(totalBytes: 8000, availableBytes: 2000)
        let monitor = LiveWorkMonitor(currentTasks: { [] }, runningApplications: { [:] },
                                      locator: { RepositoryLocator(home: "/dev/null") }, scan: { _, _ in [] },
                                      readDiskSpace: { disk }, readMemoryPressure: { .normal },
                                      readMemoryUsage: { memory }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        await monitor.refresh()
        let firstDiskReading = monitor.storageHistory.samples
        await monitor.refresh()
        #expect(monitor.memoryHistory.samples.last?.value == 430)
        #expect(monitor.memoryHistory.samples.last?.status == .normal)
        #expect(firstDiskReading.count == 1)
        #expect(firstDiskReading.first?.value == 2000)
        #expect(firstDiskReading.first?.status == .normal)
        #expect(monitor.storageHistory.samples == firstDiskReading)
    }
}
