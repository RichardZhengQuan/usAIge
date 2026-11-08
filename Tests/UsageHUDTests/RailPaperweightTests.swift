import Foundation
import Combine
import Testing
@testable import UsageHUD

@Suite struct RailPaperweightTests {
    @Test func smallToolLayersUseTheirSharesWithoutReservingRoomForLabels() {
        let configuration = PaperweightConfiguration(id: .memory, capacityBytes: 1_000, layers: [
            PaperweightLayer(id: "small", title: "Small", bytes: 1, colorHex: 0, inkHex: 0),
            PaperweightLayer(id: "larger", title: "Larger", bytes: 3, colorHex: 0, inkHex: 0),
        ], freeBytes: 996)
        let rail = PaperweightSimulation(configuration: configuration, reservesLabelSpace: false)
        let detail = PaperweightSimulation(configuration: configuration)
        #expect(abs(rail.currentLevels[0] - PaperweightConstants.liquidHeight * 0.001) < 0.000_001)
        #expect(abs(rail.currentLevels[1] - PaperweightConstants.liquidHeight * 0.004) < 0.000_001)
        #expect(detail.currentLevels == [22, 44])

        rail.setBytes([2, 6])
        rail.settle()
        #expect(abs(rail.currentLevels[1] - PaperweightConstants.liquidHeight * 0.008) < 0.000_001)
    }

    @Test func memorySharesKeepTheDetailPaperweightsToolOrderAndColours() {
        let first = WorkProcess(id: 1, name: "Claude", folder: "/repo", memoryBytes: 50, startedAt: nil, ports: [])
        let second = WorkProcess(id: 2, name: "Codex", folder: "/repo", memoryBytes: 100, startedAt: nil, ports: [])
        let summary = LiveWorkSummary(appProcesses: [.claude: [first], .chatGPT: [second]])
        let rail = RailPaperweightData.memory(summary, physicalMemory: 1_000)
        let detail = PaperweightData.memory(summary: summary, running: [], physicalMemory: 1_000)
        #expect(rail == detail)
        #expect(rail.layers.map(\.id) == ["tool-claude", "tool-chatGPT"])
        #expect(rail.layers.map(\.colorHex) == [0xE8794F, 0x9690E3])
        #expect(rail.usedBytes == 150)
    }

    @Test func theDiskHasOneLayerAndAnUnreadDiskStaysEmpty() {
        let disk = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 10))
        #expect(disk.layers.count == 1)
        #expect(disk.usedBytes == 990)
        #expect(disk.freeBytes == 10)
        let unread = RailPaperweightData.storage(nil)
        #expect(unread.usedBytes == 0)
        #expect(unread.freeBytes == nil)
        #expect(PaperweightSimulation(configuration: unread, reservesLabelSpace: false).currentLevels == [0])
    }

    @Test func diskWarningsChangeAtTheExistingSeverityThresholds() {
        #expect(RailPaperweightData.storageColor(0.01) == 0x5E9FE3)
        for threshold in [0.4, 0.6, 0.8, 0.9] {
            #expect(RailPaperweightData.storageColor(threshold - 0.001) != RailPaperweightData.storageColor(threshold + 0.001))
        }
        let warning = RailPaperweightData.storageColor(0.95)
        #expect((warning >> 16) & 255 > warning & 255)
        #expect((warning >> 16) & 255 > (warning >> 8) & 255)
    }

    @Test func theMiniShipRestsOnShallowWaterInsteadOfFloatingAboveIt() {
        let configuration = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 990))
        let simulation = PaperweightSimulation(configuration: configuration, reservesLabelSpace: false)
        let frame = RailPaperweightFrame(simulation)
        #expect(frame.boat.y == simulation.surface(at: frame.boat.x))
        simulation.shake(amplitude: 130)
        var aboveWater = true
        for _ in 0..<120 {
            simulation.step(dt: 1.0 / 20)
            let frame = RailPaperweightFrame(simulation)
            aboveWater = aboveWater && frame.boat.y >= simulation.surface(at: frame.boat.x)
        }
        #expect(aboveWater)
    }

    @MainActor
    @Test func leavingThePaperweightStopsAllDrawingUpdates() async throws {
        let configuration = RailPaperweightData.storage(DiskSpace(totalBytes: 1_000, availableBytes: 100))
        let motion = RailPaperweightMotion(configuration: configuration)
        var frames = 0
        let subscription = motion.$frame.sink { _ in frames += 1 }
        motion.update(configuration: configuration, hovered: true)
        await Task.yield()
        motion.update(configuration: configuration, hovered: false)
        let stopped = frames
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(frames == stopped)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    @Test func anEmptyHoveredPaperweightHasNoDrawingClock() async throws {
        let configuration = RailPaperweightData.storage(nil)
        let motion = RailPaperweightMotion(configuration: configuration)
        var frames = 0
        let subscription = motion.$frame.sink { _ in frames += 1 }
        motion.update(configuration: configuration, hovered: true)
        let still = frames
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(frames == still)
        withExtendedLifetime(subscription) {}
    }
}
