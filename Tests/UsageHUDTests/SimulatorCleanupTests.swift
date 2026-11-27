import Foundation
import Testing
@testable import UsageHUD

/// simctl groups devices by runtime identifier and disk images by image UUID.
enum SimulatorFixture {
    static let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!
    static let watch = "11111111-0000-4000-A000-000000000001"
    static let phone = "11111111-0000-4000-A000-000000000002"
    static let duo = "11111111-0000-4000-A000-000000000003"
    static let preview = "22222222-0000-4000-A000-000000000001"
    static let unavailable = "22222222-0000-4000-A000-000000000002"
    static let devices = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
        {"udid":"22222222-0000-4000-A000-000000000003","name":"iPhone 17","state":"Booted","isAvailable":true,"dataPathSize":1300000000}],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4":[
        {"udid":"\(preview)","name":"usAIge Preview Duo","state":"Shutdown","isAvailable":true,"lastUsedAt":"2026-11-25T12:00:00Z",
         "dataPathSize":1000000000,"dataPath":"/Users/me/Library/Developer/CoreSimulator/Devices/\(preview)/data"},
        {"udid":"22222222-0000-4000-A000-000000000004","name":"Small","state":"Shutdown","isAvailable":true,"dataPathSize":499999999},
        {"udid":"22222222-0000-4000-A000-000000000005","name":"At threshold","state":"Shutdown","isAvailable":true,
         "lastUsedAt":"2026-10-28T12:00:00.000Z","dataPathSize":500000000}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-26-5":[],
      "com.apple.CoreSimulator.SimRuntime.watchOS-10-0":[
        {"udid":"\(unavailable)","name":"Unavailable Watch","state":"Shutdown","isAvailable":false,"dataPathSize":4096}]}}
    """
    static let runtimes = """
    {
      "\(watch)":{"identifier":"\(watch)","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
        "version":"26.5","build":"23T570","deletable":true,"sizeBytes":3935033546,"lastUsedAt":"2026-10-09T08:18:44Z"},
      "\(phone)":{"identifier":"\(phone)","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "version":"26.5","build":"23F77","deletable":true,"sizeBytes":8494282293,"lastUsedAt":"2026-11-25T13:51:22Z"},
      "\(duo)":{"identifier":"\(duo)","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
        "version":"27.2","build":"24B91016s","deletable":true,"sizeBytes":8338867041,"lastUsedAt":"2026-11-25T14:04:50Z"}}
    """

    static func rows(devices: String = devices, runtimes: String = runtimes) -> [SimulatorCleanupRow]? {
        SimulatorCleaner.rows(devices: Data(devices.utf8), runtimes: Data(runtimes.utf8), now: now)
    }
}

actor FixtureSimctl {
    struct Call: Equatable {
        let arguments: [String]
        let timeout: TimeInterval
    }
    private var devices = SimulatorFixture.devices, runtimes = SimulatorFixture.runtimes
    private(set) var mutations: [Call] = []
    private(set) var reads = 0

    func update(devices: String = SimulatorFixture.devices, runtimes: String = SimulatorFixture.runtimes) {
        self.devices = devices
        self.runtimes = runtimes
    }

    func run(_ arguments: [String], _ timeout: TimeInterval) async -> CommandOutput {
        let json: String
        switch arguments {
        case ["list", "devices", "-j"]: json = devices
        case ["runtime", "list", "-j"]: json = runtimes
        default:
            mutations.append(Call(arguments: arguments, timeout: timeout))
            return CommandOutput(status: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
        }
        reads += 1
        return CommandOutput(status: 0, stdout: Data(json.utf8), stderr: Data(), timedOut: false, truncated: false)
    }
}

struct SimulatorCleanupTests {
    @Test func parsesRuntimeImagesAndDevicesAndCountsOnlySuggestedBytes() throws {
        let rows = try #require(SimulatorFixture.rows())
        let watch = try #require(rows.first { $0.target.name == "watchOS 26.5" })
        #expect(watch.isSuggested && watch.candidate != nil && watch.bytes == 3_935_033_546)
        #expect(watch.deviceCount == 0 && watch.dataPath == nil)
        let phone = try #require(rows.first { $0.target.name == "iOS 26.5" })
        #expect(phone.candidate == nil && !phone.isSuggested && phone.deviceCount == 1)
        #expect(phone.reason == "A simulator on it is running.")
        let duo = try #require(rows.first { $0.target.name == "iOS 27.2 (iPhone19,4)" })
        #expect(duo.candidate != nil && !duo.isSuggested && duo.deviceCount == 3)
        let preview = try #require(rows.first { $0.title == "usAIge Preview Duo" })
        #expect(preview.candidate != nil && !preview.isSuggested)
        #expect(preview.dataPath?.hasSuffix("/data") == true)
        let booted = try #require(rows.first { $0.title == "iPhone 17" })
        #expect(booted.candidate == nil && !booted.isSuggested && booted.reason != nil)
        #expect(!rows.contains { $0.title == "Small" })
        #expect(rows.first { $0.title == "At threshold" }?.isSuggested == true)
        #expect(rows.first { $0.title == "Unavailable Watch" }?.isSuggested == true)
        let inventory = StorageCleanupInventory(simulators: rows)
        #expect(CleanableSpace(inventory: inventory, worktrees: [], checkedWorktrees: true).bytes == 3_935_033_546 + 500_000_000 + 4096)

        let protected = SimulatorFixture.runtimes.replacingOccurrences(of: #""deletable":true"#, with: #""deletable":false"#)
        #expect(SimulatorFixture.rows(runtimes: protected)?.first { $0.id == watch.id }?.reason != nil)
        let unknownAge = SimulatorFixture.runtimes.replacingOccurrences(of: #","lastUsedAt":"2026-10-09T08:18:44Z""#, with: "")
        #expect(SimulatorFixture.rows(runtimes: unknownAge)?.first { $0.id == watch.id }?.isSuggested == false)
    }

    @Test func rechecksBothListsAndRefusesChangedTargetsWithoutMutating() async throws {
        let fake = FixtureSimctl(), source = SimulatorFixture.self
        let cleaner = SimulatorCleaner(simctl: fake.run)
        let rows = try #require(await cleaner.scan(now: source.now))
        let device = try #require(rows.first { $0.title == "usAIge Preview Duo" }?.candidate)
        let runtime = try #require(rows.first { $0.target.name.contains("iPhone19,4") }?.candidate)
        let unavailable = try #require(rows.first { $0.title == "Unavailable Watch" }?.candidate)
        let cases: [(String, String, SimulatorCleanupCandidate)] = [
            (source.devices.replacingOccurrences(of: "Shutdown", with: "Booted"), source.runtimes, device),
            (source.devices.replacingOccurrences(of: "Shutdown", with: "Booting"), source.runtimes, runtime),
            (source.devices.replacingOccurrences(of: "2026-11-25T12", with: "2026-11-26T12"), source.runtimes, device),
            (source.devices, source.runtimes.replacingOccurrences(of: "2026-11-25T14", with: "2026-11-26T14"), runtime),
            (source.devices, source.runtimes.replacingOccurrences(of: "24B91016s", with: "24B91017"), runtime),
            (source.devices, source.runtimes.replacingOccurrences(of: "24B91016s", with: "24B91017"), device),
            (source.devices, source.runtimes.replacingOccurrences(of: #""deletable":true"#, with: #""deletable":false"#), runtime),
            (source.devices.replacingOccurrences(of: #""isAvailable":false"#, with: #""isAvailable":true"#), source.runtimes, unavailable),
            (source.devices.replacingOccurrences(of: source.preview, with: UUID().uuidString), source.runtimes, device),
            (source.devices, "{}", runtime),
            ("{}", source.runtimes, runtime),
            (source.devices, "{", device)
        ]
        for (devices, runtimes, target) in cases {
            await fake.update(devices: devices, runtimes: runtimes)
            #expect(await cleaner.perform(target) != nil)
        }
        #expect(await fake.reads == 2 * (cases.count + 1))
        #expect(await fake.mutations.isEmpty)
    }

    @Test func performsOnlyReviewedCommandsWithTheirOwnTimeouts() async throws {
        let fake = FixtureSimctl()
        let cleaner = SimulatorCleaner(simctl: fake.run)
        let rows = try #require(await cleaner.scan(now: SimulatorFixture.now))
        for name in ["watchOS 26.5", "Unavailable Watch", "usAIge Preview Duo"] {
            let candidate = try #require(rows.first { $0.target.name == name }?.candidate)
            #expect(await cleaner.perform(candidate) == nil)
        }
        #expect(await fake.mutations == [
            .init(arguments: ["runtime", "delete", SimulatorFixture.watch], timeout: 300),
            .init(arguments: ["delete", SimulatorFixture.unavailable], timeout: 120),
            .init(arguments: ["erase", SimulatorFixture.preview], timeout: 120)
        ])
    }

    @MainActor @Test func mixedCleanupSharesProgressAndInvalidatesLargestFolders() async throws {
        let fixture = try GitFixture(), fake = FixtureSimctl()
        try fixture.write(".npm/_cacache/content-v2/file", "cache", in: fixture.home)
        let scanner = fixture.scanner(now: { SimulatorFixture.now }, simctl: fake.run)
        _ = await scanner.toolStorage(force: true)
        let store = BranchesStore(scanner: scanner, diskURL: URL(fileURLWithPath: fixture.home))
        await store.loadCleanupInventory()?.value
        let inventory = try #require(store.cleanupInventory)
        let folders = inventory.rows.compactMap(\.candidate)
        let simulators = inventory.simulators.filter { ["watchOS 26.5", "usAIge Preview Duo"].contains($0.target.name) }.compactMap(\.candidate)
        let selection = StorageCleanupSelection(folders: folders, simulators: simulators)
        let confirmation = selection.confirmationMessage(locale: Locale(identifier: "en_US"))
        #expect(confirmation.contains("watchOS 26.5") && confirmation.contains(BoardText.bytes(3_935_033_546)))
        #expect(confirmation.contains("apps and data") && confirmation.contains("None of the deleted or erased contents can be restored."))
        #expect(store.startStorageCleanup(selection))
        #expect(store.cleanupProgress?.total == 3)
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(15)
        while store.isDeleting, clock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
        let result = try #require(store.resultMessage)
        #expect(result.deletedCount == 3 && !result.isProblem)
        #expect(result.text.contains("Deleted 1 folder and 1 simulator runtime."))
        #expect(result.text.contains("Erased 1 simulator."))
        #expect(!FileManager.default.fileExists(atPath: fixture.home + "/.npm/_cacache"))
        #expect(await fake.mutations.map(\.arguments) == [["erase", SimulatorFixture.preview], ["runtime", "delete", SimulatorFixture.watch]])
        let cached = try JSONDecoder().decode(BranchesCacheFile.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.root + "/cache/branches.json")))
        #expect(cached.toolStorageMeasuredAt == nil)
    }
}
