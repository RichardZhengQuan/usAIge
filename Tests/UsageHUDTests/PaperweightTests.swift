import Foundation
import Testing
@testable import UsageHUD

private func paperweightFolder(_ id: String, total: Int64, cache: Int64, path: String? = nil) -> WorkItem {
    var facts = WorkFacts()
    facts.hasWorktree = true
    facts.folderExists = true
    facts.changedFiles = 0
    facts.untrackedFiles = 0
    facts.ownCommits = 1
    facts.commitsAtRisk = 0
    facts.merge = .sameCommits
    var item = WorkItem(id: id, repositoryID: "/repo/.git", repositoryName: "repo", branch: id,
                        worktreePath: path ?? "/trees/\(id)", tip: "tip", upstream: nil,
                        committedAt: nil, facts: facts, ignoredFiles: [])
    item.size = FolderSize(totalBytes: total, cacheBytes: cache, cacheBytesByName: [:],
                           ignored: [], otherIgnoredBytes: 0, measuredAt: Date(timeIntervalSince1970: 0))
    return item
}

private func paperweightProcess(_ id: Int32, bytes: UInt64) -> WorkProcess {
    WorkProcess(id: id, name: "process", folder: "/repo", memoryBytes: bytes, startedAt: nil, ports: [])
}

private func paperweightSession(_ id: String, tool: AIToolID, processes: [WorkProcess]) -> LiveSessionWork {
    LiveSessionWork(id: id, toolID: tool, title: id, phase: .thinking, updatedAt: Date(timeIntervalSince1970: 0),
                    folder: "/repo", repositoryName: "repo", branch: id, detachedAt: nil,
                    placement: .mainCopy, processes: processes)
}

private func paperweightConfiguration(_ id: PaperweightID = .storage, bytes: [Int64] = [600, 50, 100, 100], capacity: Int64 = 1_000) -> PaperweightConfiguration {
    PaperweightConfiguration(id: id, capacityBytes: capacity, layers: bytes.enumerated().map {
        PaperweightLayer(id: "layer-\($0.offset)", title: "Layer", bytes: $0.element, colorHex: 0x5E9FE3, inkHex: 0x042C53)
    }, freeBytes: max(0, capacity - bytes.reduce(0, +)))
}

@Suite struct PaperweightDataTests {
    @Test func diskCategoriesAreDisjointAndSumToObservedUse() {
        let board = BranchesBoard(safeToClear: [
            paperweightFolder("a", total: 300, cache: 100),
            paperweightFolder("b", total: 100, cache: 20),
        ])
        let config = PaperweightData.storage(disk: DiskSpace(totalBytes: 1_000, availableBytes: 200), board: board,
                                            toolStorage: [.init(name: "Tools", path: nil, bytes: 50, kind: .history)], isMeasuring: false)
        #expect(config.layers.map(\.id) == ["other", "tool", "cache", "wt"])
        #expect(config.layers.map(\.bytes) == [350, 50, 120, 280])
        #expect(config.usedBytes == 800)
        #expect(config.freeBytes == 200)
        #expect(config.usedBytes + (config.freeBytes ?? 0) == config.capacityBytes)
        #expect(config.freeLayer.id == "free")
        #expect(!config.allocationIsEstimated)
    }

    @Test func overlapEstimatesAreBoundedWithoutInventingAZeroCategory() {
        let board = BranchesBoard(safeToClear: [paperweightFolder("a", total: 200, cache: 200)])
        let config = PaperweightData.storage(disk: DiskSpace(totalBytes: 1_000, availableBytes: 999), board: board,
                                            toolStorage: [.init(name: "Tools", path: nil, bytes: 200, kind: .runtime)], isMeasuring: false)
        #expect(config.allocationIsEstimated)
        #expect(config.measuredBytes == 400)
        #expect(config.usedBytes == 1)
        #expect(config.layers.last?.bytes == 0)
        #expect(config.layers.allSatisfy { $0.bytes >= 0 })
        #expect(config.usedBytes + (config.freeBytes ?? 0) == config.capacityBytes)
    }

    @Test func previewRemovesTheChosenCacheAndFolderPartsOnly() {
        let board = BranchesBoard(safeToClear: [paperweightFolder("a", total: 400, cache: 120)])
        let config = PaperweightData.storage(disk: DiskSpace(totalBytes: 1_000, availableBytes: 200), board: board,
                                            toolStorage: [.init(name: "Tools", path: nil, bytes: 50, kind: .history)],
                                            isMeasuring: false, freeing: 150, freeingCacheBytes: 50)
        #expect(config.layers.map(\.bytes) == [350, 50, 70, 180])
        #expect(config.usedBytes == 650)
        #expect(config.freeBytes == 350)
    }

    @Test func folderAliasesAndCachesLargerThanTheirFolderDoNotDoubleCount() {
        let first = paperweightFolder("first", total: 100, cache: 200, path: "/var/tmp/tree/.")
        let alias = paperweightFolder("alias", total: 100, cache: 200, path: "/private/var/tmp/tree")
        let board = BranchesBoard(needsLook: [.item(first)], safeToClear: [alias])
        let config = PaperweightData.storage(disk: DiskSpace(totalBytes: 1_000, availableBytes: 800), board: board,
                                            toolStorage: [], isMeasuring: false)
        #expect(config.layers.map(\.bytes) == [100, 0, 100, 0])
    }

    @Test func anUnreadDiskKeepsKnownMeasurementsButDoesNotClaimFreeSpace() {
        let config = PaperweightData.storage(disk: nil, board: BranchesBoard(safeToClear: [paperweightFolder("a", total: 100, cache: 40)]),
                                            toolStorage: [], isMeasuring: true)
        #expect(config.capacityBytes == 0)
        #expect(config.freeBytes == nil)
        #expect(config.freeLayer.isMeasuring)
        #expect(config.layers[0].isMeasuring)
        #expect(config.layers[1].isMeasuring)
        #expect(config.layers[2].bytes == 40)
        #expect(config.layers[3].bytes == 60)
    }

    @Test func memoryAttributesEachProcessOnceAcrossToolsAndDevServers() {
        let shared = paperweightProcess(1, bytes: 100)
        let helper = paperweightProcess(2, bytes: 200)
        let codex = paperweightProcess(3, bytes: 300)
        let server = paperweightProcess(4, bytes: 400)
        let summary = LiveWorkSummary(sessions: [
            paperweightSession("claude", tool: .claude, processes: [shared]),
            paperweightSession("codex", tool: .chatGPT, processes: [shared, codex]),
        ], appProcesses: [.claude: [helper, helper]])
        var first = paperweightFolder("first", total: 0, cache: 0)
        first.processes = [shared, helper, codex, server]
        var second = first
        second.processes = [server]
        let config = PaperweightData.memory(summary: summary, running: [first, second], physicalMemory: 2_000)
        #expect(config.usedBytes == 1_000)
        #expect(config.freeBytes == 1_000)
        #expect(config.freeLayer.id == "mfree")
        #expect(config.layers.first { $0.id == "dev" }?.processIDs == [4])
        #expect(config.layers.first { $0.id == "tool-chatGPT" }?.processIDs == [1, 3])
        #expect(config.layers.first { $0.id == "tool-claude" }?.processIDs == [2])
        #expect(config.layers.first { $0.id == "tool-claude" }?.colorHex == 0xE8794F)
        #expect(config.layers.first { $0.id == "tool-chatGPT" }?.colorHex == 0x9690E3)
        #expect(Set(config.layers.flatMap(\.processIDs)).count == 4)
    }

    @Test func overcommittedMemoryKeepsMeasuredBytesAndDisclosesTheEstimate() {
        let summary = LiveWorkSummary(sessions: [paperweightSession("a", tool: .claude, processes: [paperweightProcess(1, bytes: 2_000)])])
        let config = PaperweightData.memory(summary: summary, running: [], physicalMemory: 1_000)
        #expect(config.usedBytes == 2_000)
        #expect(config.freeBytes == 0)
        #expect(config.allocationIsEstimated)
        #expect((PaperweightSimulation(configuration: config).currentLevels.last ?? 0) <= PaperweightConstants.liquidHeight)
    }

    @Test func noObservedProcessesMakeAnEmptyMemoryTank() {
        let config = PaperweightData.memory(summary: LiveWorkSummary(), running: [], physicalMemory: 1_000)
        #expect(config.layers.isEmpty)
        #expect(config.usedBytes == 0)
        #expect(config.freeBytes == 1_000)
        #expect(PaperweightSimulation(configuration: config).surface(at: 220) == 0)
    }
}

@Suite struct PaperweightSimulationTests {
    @Test func thePrototypeDimensionsAndSmallLayerBandsArePreserved() {
        #expect(PaperweightConstants.BW == 4)
        #expect(PaperweightConstants.BH == 1.9)
        #expect(PaperweightConstants.BD == 1.1)
        #expect(PaperweightConstants.BR == 0.22)
        #expect(PaperweightConstants.sampleCount == 64)
        #expect(abs(PaperweightConstants.liquidHeight - (1.74 / (3.8 / 440) - PaperweightConstants.boatHeight - 8)) < 0.00001)
        let disk = PaperweightSimulation(configuration: paperweightConfiguration(bytes: [1, 1, 1, 1]))
        #expect(disk.currentLevels == [4, 26, 48, 70])
        let memory = PaperweightSimulation(configuration: paperweightConfiguration(.memory, bytes: [1, 1, 1]))
        #expect(memory.currentLevels == [22, 44, 66])
        #expect(disk.waveHeights.count == 64)
    }

    @Test func zeroBytesLeaveNoLiquidAndNoInvalidSurface() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration(bytes: [0, 0, 0, 0], capacity: 0))
        simulation.shake(amplitude: 240)
        simulation.step(dt: 1.0 / 60)
        simulation.settle()
        #expect(simulation.currentLevels == [0, 0, 0, 0])
        #expect(simulation.surface(at: 220) == 0)
        #expect(simulation.curve(layer: -1, sample: 0) == 0)
        #expect(simulation.energy == 0)
    }

    @Test func aShakeIsRepeatableAndEventuallyStopsAllMotion() {
        let first = PaperweightSimulation(configuration: paperweightConfiguration())
        let second = PaperweightSimulation(configuration: paperweightConfiguration())
        first.shake(amplitude: 240)
        second.shake(amplitude: 240)
        #expect(!first.isSettled)
        for _ in 0..<60 { first.step(dt: 1.0 / 60); second.step(dt: 1.0 / 60) }
        #expect(first.waveHeights == second.waveHeights)
        #expect(first.boat == second.boat)
        for _ in 0..<7_200 {
            first.step(dt: 1.0 / 60)
            if first.isSettled { break }
        }
        #expect(first.isSettled)
        #expect(first.waveHeights.allSatisfy { $0 == 0 })
        #expect(first.boat.velocityX == 0)
        #expect(first.boat.velocityY == 0)
        #expect(first.boat.angularVelocity == 0)
    }

    @Test func aSplashMakesALocalDip() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration())
        let before = simulation.surface(at: 220)
        simulation.splash(x: 220)
        simulation.step(dt: 1.0 / 120)
        #expect(simulation.surface(at: 220) < before)
        #expect(simulation.waveHeights[31] < 0)
        #expect(abs(simulation.waveHeights[31]) > abs(simulation.waveHeights[0]))
    }

    @Test func aLowLayerKeepsTheKeelAboveTheGlassFloor() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration(.memory, bytes: [1]))
        #expect(simulation.boat.y >= PaperweightConstants.boatDraft)
        simulation.shake(amplitude: 400)
        var inside = true
        for _ in 0..<600 {
            simulation.step(dt: 1.0 / 60)
            inside = inside && simulation.boat.y >= PaperweightConstants.boatDraft
                && simulation.boat.y >= simulation.surface(at: simulation.boat.x)
        }
        #expect(inside)
        simulation.settle()
        #expect(simulation.boat.y >= PaperweightConstants.boatDraft)
    }

    @Test func theShipNeverCrossesTheLiquidOrLidOrMaximumRoll() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration())
        simulation.shake(amplitude: 1_000)
        var safe = true
        for index in 0..<600 {
            simulation.acceleration = 0.4 * sin(Double(index) * 0.08)
            simulation.tiltTarget = 0.09 * sin(Double(index) * 0.04)
            simulation.step(dt: 1.0 / 60)
            safe = safe && simulation.boat.x >= PaperweightConstants.boatMargin
                && simulation.boat.x <= PaperweightConstants.textureWidth - PaperweightConstants.boatMargin
                && simulation.boat.y >= simulation.surface(at: simulation.boat.x)
                && simulation.boat.y >= PaperweightConstants.boatDraft
                && simulation.boat.y <= PaperweightConstants.boatCeiling
                && abs(simulation.boat.angle) <= 0.35
            for sample in 0..<64 {
                safe = safe && simulation.curve(layer: 3, sample: sample) <= PaperweightConstants.boatCeiling + 0.00001
            }
        }
        #expect(safe)
    }

    @Test func droppingAShipWaitsForTheImpactBeforeMakingADip() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration(.memory, bytes: [200], capacity: 1_000))
        let water = simulation.surface(at: simulation.boat.x)
        simulation.dropShip()
        #expect(simulation.boat.y > water)
        #expect(simulation.boat.y <= PaperweightConstants.boatCeiling)
        #expect(simulation.boat.velocityY == -30)
        for _ in 0..<20 { simulation.step(dt: 0.01) }
        #expect(simulation.waveHeights.allSatisfy { $0 == 0 })
        #expect(!simulation.isSettled)
        for _ in 0..<7 { simulation.step(dt: 0.01) }
        #expect(simulation.surface(at: simulation.boat.x) < water)
        #expect(simulation.waveHeights.contains { $0 < 0 })
        #expect(simulation.boat.y >= simulation.surface(at: simulation.boat.x))
        for _ in 0..<7_200 {
            simulation.step(dt: 1.0 / 60)
            if simulation.isSettled { break }
        }
        #expect(simulation.isSettled)
    }

    @Test func reduceMotionSettlingCancelsThePendingDropSplash() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration(.memory, bytes: [200], capacity: 1_000))
        simulation.dropShip()
        simulation.settle()
        for _ in 0..<30 { simulation.step(dt: 0.01) }
        #expect(simulation.waveHeights.allSatisfy { $0 == 0 })
        #expect(simulation.energy == 0)
        #expect(simulation.isSettled)
    }

    @Test func settlingAppliesNewLayerSizesImmediatelyForReduceMotion() {
        let simulation = PaperweightSimulation(configuration: paperweightConfiguration())
        simulation.shake(amplitude: 150)
        simulation.setBytes([600, 50, 40, 20])
        #expect(simulation.currentLevels != simulation.targetLevels)
        simulation.settle()
        #expect(simulation.currentLevels == simulation.targetLevels)
        #expect(simulation.configuration.usedBytes == 710)
        #expect(simulation.configuration.freeBytes == 290)
        #expect(simulation.energy == 0)
        #expect(simulation.boat.y == simulation.surface(at: simulation.boat.x))
    }
}
