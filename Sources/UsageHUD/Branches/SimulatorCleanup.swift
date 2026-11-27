import Foundation

enum SimulatorCleanupAction: Equatable, Sendable {
    case deleteUnavailableDevice(UUID)
    case deleteRuntime(UUID)
    case eraseDevice(UUID)

    var identifier: UUID {
        switch self { case let .deleteUnavailableDevice(id), let .deleteRuntime(id), let .eraseDevice(id): id }
    }

    var isRuntime: Bool {
        if case .deleteRuntime = self { return true }
        return false
    }

    var arguments: [String] {
        switch self {
        case let .deleteUnavailableDevice(id): ["delete", id.uuidString]
        case let .deleteRuntime(id): ["runtime", "delete", id.uuidString]
        case let .eraseDevice(id): ["erase", id.uuidString]
        }
    }

    var consequence: String {
        switch self {
        case .deleteUnavailableDevice: "This unavailable simulator and its data will be deleted."
        case .deleteRuntime: "Download the runtime again in Xcode to use its simulators."
        case .eraseDevice: "Erasing removes the apps and data and keeps the simulator and its name."
        }
    }
}

/// The identity and observations approved in the confirmation sheet.
struct SimulatorCleanupCandidate: Identifiable, Equatable, Sendable {
    let action: SimulatorCleanupAction
    let name: String
    let runtimeIdentifier: String
    let builds: [String]
    let lastUsedAt: String?
    let bytes: Int64?
    var state: String?
    var version: String?

    var id: String { action.arguments.joined(separator: "/") }
    var title: String {
        if case .deleteRuntime = action { return AppLanguage.format("%@ simulator runtime", name) }
        return name
    }
}

struct SimulatorCleanupRow: Identifiable, Equatable, Sendable {
    let target: SimulatorCleanupCandidate
    let reason: String?
    let isSuggested: Bool
    let lastUse: Date?
    let scannedAt: Date
    var deviceCount: Int?
    var dataPath: String?

    var id: String { target.id }
    var title: String { target.title }
    var bytes: Int64? { target.bytes }
    var candidate: SimulatorCleanupCandidate? { reason == nil ? target : nil }
    var detail: String {
        var parts: [String] = []
        if let deviceCount {
            parts.append(target.builds.joined(separator: ", "))
            parts.append(deviceCount == 1 ? AppLanguage.text("1 simulator") : AppLanguage.format("%lld simulators", deviceCount))
        } else {
            parts.append(ToolStorageScanner.runtimeName(target.runtimeIdentifier))
        }
        if let lastUse {
            let relative = RelativeDateTimeFormatter()
            relative.locale = AppLanguage.current.locale
            let weeks = Int(scannedAt.timeIntervalSince(lastUse) / (7 * 86400))
            let when = (1...11).contains(weeks)
                ? relative.localizedString(from: DateComponents(weekOfMonth: -weeks))
                : relative.localizedString(for: lastUse, relativeTo: scannedAt)
            parts.append(AppLanguage.format("Last used %@", when))
        } else {
            parts.append(AppLanguage.text("Last use unknown"))
        }
        return parts.joined(separator: " · ")
    }
}

struct SimulatorCleaner: Sendable {
    typealias Runner = @Sendable ([String], TimeInterval) async -> CommandOutput
    let simctl: Runner

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator") }

    static func runLive(_ arguments: [String], timeout: TimeInterval) async -> CommandOutput {
        // xcrun can offer to install developer tools when CoreSimulator is absent.
        guard isInstalled else { return .couldNotStart }
        return await CommandRunner.run(ShellCommand(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                                   arguments: ["simctl"] + arguments), timeout: timeout)
    }

    static func isOld(_ date: Date?, now: Date) -> Bool {
        date.map { now.timeIntervalSince($0) >= 30 * 86400 } ?? false
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: UUID
        let name: String
        let state: String
        let isAvailable: Bool
        let lastUsedAt: String?
        let dataPathSize: Int64?
        let dataPath: String?
    }

    private struct Runtime: Decodable {
        let identifier: UUID?
        let runtimeIdentifier: String
        let version: String
        let build: String
        let deletable: Bool
        let sizeBytes: Int64
        let lastUsedAt: String?
    }

    /// A failed or partial device list must never look like an idle runtime.
    static func rows(devices deviceJSON: Data, runtimes runtimeJSON: Data, now: Date) -> [SimulatorCleanupRow]? {
        let decoder = JSONDecoder()
        guard let devices = try? decoder.decode(DeviceList.self, from: deviceJSON).devices,
              let runtimes = try? decoder.decode([String: Runtime].self, from: runtimeJSON) else { return nil }
        let dateFormat = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        func date(_ raw: String?) -> Date? { raw.flatMap { dateFormat.date(from: $0) ?? fractional.date(from: $0) } }
        var rows: [SimulatorCleanupRow] = []
        var runtimeIDs: Set<UUID> = []
        var builds: [String: [String]] = [:]
        for (key, runtime) in runtimes {
            guard let uuid = UUID(uuidString: key), runtimeIDs.insert(uuid).inserted,
                  runtime.identifier == nil || runtime.identifier == uuid, runtime.sizeBytes >= 0,
                  !runtime.runtimeIdentifier.isEmpty, !runtime.build.isEmpty, !runtime.version.isEmpty else { return nil }
            builds[runtime.runtimeIdentifier, default: []].append(runtime.build)
            let members = devices[runtime.runtimeIdentifier] ?? []
            let running = members.contains { $0.state == "Booted" || $0.state == "Booting" }
            let reason = running ? "A simulator on it is running."
                : runtime.deletable ? nil : "Xcode marks this runtime as non-deletable."
            let lastUse = date(runtime.lastUsedAt)
            let target = SimulatorCleanupCandidate(action: .deleteRuntime(uuid), name: ToolStorageScanner.runtimeName(runtime.runtimeIdentifier),
                                                   runtimeIdentifier: runtime.runtimeIdentifier, builds: [runtime.build],
                                                   lastUsedAt: runtime.lastUsedAt, bytes: runtime.sizeBytes, version: runtime.version)
            rows.append(SimulatorCleanupRow(target: target, reason: reason, isSuggested: reason == nil && isOld(lastUse, now: now),
                                            lastUse: lastUse, scannedAt: now, deviceCount: members.count))
        }
        var deviceIDs: Set<UUID> = []
        for (runtime, members) in devices {
            for device in members {
                guard deviceIDs.insert(device.udid).inserted, (device.dataPathSize ?? 0) >= 0 else { return nil }
                guard !device.isAvailable || (device.dataPathSize ?? 0) >= 500_000_000 else { continue }
                let reason = device.isAvailable && device.state != "Shutdown" ? "Shut down the simulator before erasing it." : nil
                let action: SimulatorCleanupAction = device.isAvailable ? .eraseDevice(device.udid) : .deleteUnavailableDevice(device.udid)
                let target = SimulatorCleanupCandidate(action: action, name: device.name, runtimeIdentifier: runtime,
                                                       builds: (builds[runtime] ?? []).sorted(), lastUsedAt: device.lastUsedAt,
                                                       bytes: device.dataPathSize, state: device.state)
                let lastUse = date(device.lastUsedAt)
                rows.append(SimulatorCleanupRow(target: target, reason: reason,
                                                isSuggested: reason == nil && (!device.isAvailable || isOld(lastUse, now: now)),
                                                lastUse: lastUse, scannedAt: now, dataPath: device.dataPath))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    func scan(now: Date) async -> [SimulatorCleanupRow]? {
        async let devices = simctl(["list", "devices", "-j"], 30)
        async let runtimes = simctl(["runtime", "list", "-j"], 30)
        let (deviceList, runtimeList) = await (devices, runtimes)
        guard deviceList.succeeded, runtimeList.succeeded else { return nil }
        return Self.rows(devices: deviceList.stdout, runtimes: runtimeList.stdout, now: now)
    }

    func perform(_ candidate: SimulatorCleanupCandidate) async -> String? {
        guard let rows = await scan(now: Date()) else { return AppLanguage.text("Could not verify the simulator inventory.") }
        guard let row = rows.first(where: { $0.id == candidate.id }) else {
            return AppLanguage.text("The simulator item is gone or no longer eligible. Scan again to review it.")
        }
        if let reason = row.reason { return AppLanguage.text(reason) }
        guard row.candidate == candidate else { return AppLanguage.text("The simulator item changed. Scan again to review it.") }
        let result = await simctl(candidate.action.arguments, candidate.action.isRuntime ? 300 : 120)
        guard !result.succeeded else { return nil }
        if result.timedOut { return AppLanguage.text("The simulator operation timed out. Scan again to check its state.") }
        return result.errorText.isEmpty ? AppLanguage.text("The simulator operation failed.") : result.errorText
    }
}
