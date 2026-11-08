import Combine
import Foundation
import Testing
@testable import UsageHUD

@Suite struct ResourceWeatherStatusTests {
    @Test func pressureReadingsUseDispatchFlagsRatherThanTheKernelInternalEnum() {
        #expect(SystemMemoryPressure(dispatchLevel: 1) == .normal)
        #expect(SystemMemoryPressure(dispatchLevel: 2) == .warning)
        #expect(SystemMemoryPressure(dispatchLevel: 4) == .critical)
        for value: UInt32 in [0, 3, 8, .max] {
            #expect(SystemMemoryPressure(dispatchLevel: value) == .unknown)
        }
    }

    @Test func memoryWeatherFollowsSystemPressureWithoutUsingTheDiskOrProcessFootprint() {
        let fullDisk = DiskSpace(totalBytes: 1_000, availableBytes: 0)
        let normal = ResourceWeatherStatus.make(for: .memory, memoryPressure: .normal, disk: fullDisk)
        #expect(normal.weather == .sunny)
        #expect(normal.summary == "Memory pressure normal")
        #expect(ResourceWeatherStatus.make(for: .memory, memoryPressure: .warning, disk: nil).weather == .rain)
        #expect(ResourceWeatherStatus.make(for: .memory, memoryPressure: .critical, disk: nil).weather == .storm)
        let unknown = ResourceWeatherStatus.make(for: .memory, memoryPressure: .unknown, disk: nil)
        #expect(unknown.weather == .cloudy)
        #expect(unknown.summary == "Memory pressure unavailable")
    }

    @Test func storageWeatherWarnsAtTwentyTenAndFivePercentFree() {
        let cases: [(available: Int64, weather: CruiseWeather)] = [
            (10_000, .sunny), (2_001, .sunny), (2_000, .cloudy),
            (1_001, .cloudy), (1_000, .rain), (501, .rain), (500, .storm), (0, .storm)
        ]
        for value in cases {
            let disk = DiskSpace(totalBytes: 10_000, availableBytes: value.available)
            let status = ResourceWeatherStatus.make(for: .storage, memoryPressure: .critical, disk: disk)
            #expect(status.weather == value.weather)
        }
        #expect(ResourceWeatherStatus.make(for: .storage, memoryPressure: .unknown,
                                          disk: DiskSpace(totalBytes: 1_000, availableBytes: 150)).summary == "Storage 15% free")
    }

    @Test func unreadableOrInvalidDiskDoesNotPretendToBeHealthyOrFull() {
        let readings: [DiskSpace?] = [nil, .init(totalBytes: 0, availableBytes: 0),
                                     .init(totalBytes: -1, availableBytes: 1),
                                     .init(totalBytes: .max, availableBytes: .min)]
        for reading in readings {
            let status = ResourceWeatherStatus.make(for: .storage, memoryPressure: .normal, disk: reading)
            #expect(status.weather == .cloudy)
            #expect(status.summary == "Storage status unavailable")
        }
        let overreported = ResourceWeatherStatus.make(for: .storage, memoryPressure: .normal,
                                                      disk: .init(totalBytes: 1, availableBytes: .max))
        #expect(overreported.weather == .sunny)
        #expect(overreported.summary == "Storage 100% free")
    }

    @Test func automaticUsesTheResourceAndManualConditionsRemainOverrides() {
        let status = ResourceWeatherStatus.make(for: .memory, memoryPressure: .critical, disk: nil)
        #expect(status.resolvedWeather(preference: .automatic) == .storm)
        for preference in CruiseWeather.allCases where preference != .automatic {
            #expect(status.resolvedWeather(preference: preference) == preference)
        }
    }
}

private final class PressureSample: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemMemoryPressure.normal
    private var mainThreadReads: [Bool] = []

    func set(_ value: SystemMemoryPressure) { lock.withLock { self.value = value } }
    func read() -> SystemMemoryPressure {
        lock.withLock {
            mainThreadReads.append(Thread.isMainThread)
            return value
        }
    }
    var count: Int { lock.withLock { mainThreadReads.count } }
    var readOnMainThread: Bool { lock.withLock { mainThreadReads.contains(true) } }
}

private final class PressurePublications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SystemMemoryPressure] = []
    func record(_ value: SystemMemoryPressure) { lock.withLock { values.append(value) } }
    var all: [SystemMemoryPressure] { lock.withLock { values } }
}

@MainActor
@Suite struct ResourceWeatherSamplingTests {
    @Test func sharedDiskReadingsUpdateBothStorageWeatherAndLayersWithoutRepeatPublications() {
        let first = DiskSpace(totalBytes: 1_000, availableBytes: 400)
        let full = DiskSpace(totalBytes: 1_000, availableBytes: 40)
        let store = BranchesStore(initialDiskSpace: first)
        var publications: [DiskSpace?] = []
        let observation = store.$diskSpace.sink { publications.append($0) }
        defer { observation.cancel() }

        store.updateObservedDiskSpace(first)
        store.updateObservedDiskSpace(full)
        store.updateObservedDiskSpace(full)
        #expect(publications == [first, full])
        #expect(ResourceWeatherStatus.make(for: .storage, memoryPressure: .normal, disk: store.diskSpace).weather == .storm)
        let board = BranchesBoard.make(snapshot: store.snapshot, now: Date())
        let configuration = PaperweightData.storage(disk: store.diskSpace, board: board,
                                                   toolStorage: [], isMeasuring: false)
        #expect(configuration.freeBytes == 40)
        #expect(configuration.usedBytes == 960)

        store.updateObservedDiskSpace(nil)
        store.updateObservedDiskSpace(nil)
        #expect(publications == [first, full, nil])
        #expect(ResourceWeatherStatus.make(for: .storage, memoryPressure: .normal, disk: store.diskSpace).summary
                == "Storage status unavailable")
        #expect(PaperweightData.storage(disk: store.diskSpace, board: board,
                                       toolStorage: [], isMeasuring: false).freeBytes == nil)
    }

    @Test func pressureUsesTheExistingOffMainRefreshAndPublishesOnlyChanges() async {
        let sample = PressureSample()
        let monitor = LiveWorkMonitor(currentTasks: { [] }, runningApplications: { [:] },
                                      locator: { RepositoryLocator(home: "/resource-weather-tests", allowedFolders: []) },
                                      scan: { _, _ in [] }, readDiskSpace: { nil },
                                      readMemoryPressure: { sample.read() })
        let publications = PressurePublications()
        let observation = monitor.$memoryPressure.sink { publications.record($0) }
        defer { observation.cancel() }
        #expect(monitor.memoryPressure == .unknown)
        #expect(sample.count == 0)

        await monitor.refresh()
        await monitor.refresh()
        #expect(sample.count == 2)
        #expect(!sample.readOnMainThread)
        #expect(publications.all == [.unknown, .normal])

        sample.set(.warning)
        await monitor.refresh()
        #expect(monitor.memoryPressure == .warning)
        sample.set(.unknown)
        await monitor.refresh()
        await monitor.refresh()
        #expect(publications.all == [.unknown, .normal, .warning, .unknown])
        #expect(sample.count == 5)
    }
}
