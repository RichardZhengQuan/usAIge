import Testing
@testable import UsageHUD

@Suite struct SystemCPUUsageTests {
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
        monitor.sample()
        #expect(monitor.usage == nil)
        monitor.sample()
        #expect(monitor.usage?.busy == 0)
        monitor.sample()
        #expect(monitor.usage == nil)
        monitor.sample()
        #expect(monitor.usage == nil)
        monitor.sample()
        #expect(monitor.usage?.busy == 1)
        monitor.stop()
        #expect(monitor.usage == nil)
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
