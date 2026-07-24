import AppKit
import Combine
import CryptoKit
import Foundation
import UserNotifications

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let downloadURL: URL
    let sha256: String
    var releaseNotes: ReleaseNotes? = nil

    func isNewer(thanBuild currentBuild: Int) -> Bool {
        build > currentBuild
    }

    func validate() throws {
        guard build > 0 else { throw UpdateError.invalidManifest }
        guard downloadURL.scheme?.lowercased() == "https" else {
            throw UpdateError.invalidManifest
        }
        let normalizedHash = sha256.lowercased()
        guard normalizedHash.count == 64,
              normalizedHash.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.invalidManifest
        }
        try releaseNotes?.validate()
    }

    static func newest(in manifests: [UpdateManifest]) -> UpdateManifest? {
        manifests.max(by: { $0.build < $1.build })
    }
}

struct ReleaseHighlight: Codable, Equatable, Sendable, Identifiable {
    let title: String
    let detail: String
    let systemImage: String

    var id: String { title }
}

struct ReleaseNotes: Codable, Equatable, Sendable {
    let headline: String
    let summary: String
    let highlights: [ReleaseHighlight]

    func validate() throws {
        guard !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              headline.count <= 100,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.count <= 300,
              highlights.count <= 8,
              highlights.allSatisfy({
                  !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.title.count <= 100
                      && !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.detail.count <= 300
                      && !$0.systemImage.isEmpty
                      && $0.systemImage.count <= 80
              }) else {
            throw UpdateError.invalidManifest
        }
    }
}

struct ReleaseNotesDocument: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let releaseNotes: ReleaseNotes
}

struct WhatsNewPresentation: Equatable, Sendable {
    let version: String
    let build: Int
    let releaseNotes: ReleaseNotes
    let isAvailableUpdate: Bool
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateManifest)
    case downloading(UpdateManifest)
    case preparing(UpdateManifest)
    case failed(String)
    case unavailableInDevelopment

    var primaryButtonTitle: String {
        switch self {
        case let .available(manifest):
            "Update to \(manifest.version)"
        case .checking:
            "Checking…"
        case .downloading:
            "Downloading…"
        case .preparing:
            "Installing…"
        default:
            "Check for Updates"
        }
    }

    var isPrimaryActionEnabled: Bool {
        switch self {
        case .checking, .downloading, .preparing, .unavailableInDevelopment:
            false
        default:
            true
        }
    }
}

@MainActor
final class UpdateController: ObservableObject {
    nonisolated static let notificationCategory = "USAGE_HUD_UPDATE"
    nonisolated static let notificationIdentifierPrefix = "usaige-update-"
    nonisolated static let currentManifestURL = URL(
        string: "https://usaige-macos.richardqz.chatgpt.site/update.json"
    )!
    nonisolated static let legacyManifestURL = URL(
        string: "https://pmrichq.com/project/usaige/update.json"
    )!
    nonisolated static let defaultManifestURLs = [currentManifestURL, legacyManifestURL]
    nonisolated static let automaticCheckIntervalNanoseconds: UInt64 =
        30 * 60 * 1_000_000_000

    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var isReplacementPrepared = false

    private let manifestURLs: [URL]
    private let currentVersion: String
    private let currentBuild: Int
    private let applicationURL: URL
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let installer: UpdateInstaller
    private let bundledReleaseNotes: ReleaseNotesDocument?
    private var pollingTask: Task<Void, Never>?

    private static let pendingManifestKey = "update.pendingWhatsNewManifest.v1"

    var availableUpdate: UpdateManifest? {
        guard case let .available(manifest) = status else { return nil }
        return manifest
    }

    var canInstallUpdate: Bool { availableUpdate != nil }

    var whatsNewPresentation: WhatsNewPresentation {
        if let manifest = availableUpdate, let releaseNotes = manifest.releaseNotes {
            return WhatsNewPresentation(
                version: manifest.version,
                build: manifest.build,
                releaseNotes: releaseNotes,
                isAvailableUpdate: true
            )
        }
        if let pending = pendingManifest, pending.build == currentBuild,
           let releaseNotes = pending.releaseNotes {
            return WhatsNewPresentation(
                version: pending.version,
                build: pending.build,
                releaseNotes: releaseNotes,
                isAvailableUpdate: false
            )
        }
        if let bundledReleaseNotes, bundledReleaseNotes.build == currentBuild {
            return WhatsNewPresentation(
                version: bundledReleaseNotes.version,
                build: bundledReleaseNotes.build,
                releaseNotes: bundledReleaseNotes.releaseNotes,
                isAvailableUpdate: false
            )
        }
        return WhatsNewPresentation(
            version: currentVersion,
            build: currentBuild,
            releaseNotes: ReleaseNotes(
                headline: "You’re up to date",
                summary: "You’re using the latest installed version of usAIge.",
                highlights: []
            ),
            isAvailableUpdate: false
        )
    }

    var shouldPresentWhatsNewAfterLaunch: Bool {
        guard let pending = pendingManifest else { return false }
        return pending.build == currentBuild && pending.releaseNotes != nil
    }

    var currentVersionText: String {
        currentBuild > 0 ? "\(currentVersion) (\(currentBuild))" : currentVersion
    }

    var statusText: String {
        switch status {
        case .idle:
            "Check whenever you like"
        case .checking:
            "Checking for updates…"
        case .upToDate:
            "You’re up to date!"
        case let .available(manifest):
            "Version \(manifest.version) is ready"
        case .downloading:
            "Downloading update…"
        case .preparing:
            "Verifying and preparing update…"
        case let .failed(message):
            message
        case .unavailableInDevelopment:
            "Software updates require the packaged app"
        }
    }

    var primaryButtonTitle: String { status.primaryButtonTitle }

    var canPerformPrimaryAction: Bool { status.isPrimaryActionEnabled }

    init(
        bundle: Bundle = .main,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        installer: UpdateInstaller = UpdateInstaller(),
        manifestURLs: [URL]? = nil
    ) {
        let configuredURLs = (bundle.object(forInfoDictionaryKey: "UpdateManifestURLs") as? [String])?
            .compactMap(URL.init(string:))
        let legacyConfiguredURL = (bundle.object(forInfoDictionaryKey: "UpdateManifestURL") as? String)
            .flatMap(URL.init(string:))
        self.manifestURLs = manifestURLs
            ?? configuredURLs?.nilIfEmpty
            ?? legacyConfiguredURL.map { [$0] }
            ?? Self.defaultManifestURLs
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        applicationURL = bundle.bundleURL
        bundledReleaseNotes = Self.loadBundledReleaseNotes(from: bundle)
        self.session = session
        self.userDefaults = userDefaults
        self.installer = installer
    }

    func start() {
        guard pollingTask == nil else { return }
        guard applicationURL.pathExtension == "app" else {
            status = .unavailableInDevelopment
            return
        }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                do {
                    try await Task.sleep(nanoseconds: Self.automaticCheckIntervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func checkForUpdates() async {
        switch status {
        case .checking, .downloading, .preparing:
            return
        default:
            break
        }

        status = .checking
        do {
            var manifests: [UpdateManifest] = []
            for manifestURL in manifestURLs {
                do {
                    manifests.append(try await loadManifest(from: manifestURL))
                } catch {
                    continue
                }
            }
            guard let manifest = UpdateManifest.newest(in: manifests) else {
                throw UpdateError.feedUnavailable
            }
            if manifest.isNewer(thanBuild: currentBuild) {
                status = .available(manifest)
                await notifyIfNeeded(for: manifest)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(UpdateError.userFacingMessage(for: error))
        }
    }

    private func loadManifest(from url: URL) async throws -> UpdateManifest {
        let (data, response) = try await session.data(for: Self.manifestRequest(for: url))
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.feedUnavailable
        }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    nonisolated static func manifestRequest(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    func installAvailableUpdate() async {
        guard let manifest = availableUpdate else { return }
        status = .downloading(manifest)
        do {
            let downloadedDMG = try await installer.download(
                manifest: manifest,
                using: session
            )
            status = .preparing(manifest)
            try await installer.prepareAndLaunchReplacement(
                dmgURL: downloadedDMG,
                manifest: manifest,
                currentApplicationURL: applicationURL
            )
            if manifest.releaseNotes != nil,
               let data = try? JSONEncoder().encode(manifest) {
                userDefaults.set(data, forKey: Self.pendingManifestKey)
            }
            isReplacementPrepared = true
            NSApplication.shared.terminate(nil)
        } catch {
            status = .failed(UpdateError.userFacingMessage(for: error))
        }
    }

    func performPrimaryAction() async {
        if canInstallUpdate {
            await installAvailableUpdate()
        } else {
            await checkForUpdates()
        }
    }

    func markWhatsNewPresented() {
        guard pendingManifest?.build == currentBuild else { return }
        userDefaults.removeObject(forKey: Self.pendingManifestKey)
    }

    private var pendingManifest: UpdateManifest? {
        guard let data = userDefaults.data(forKey: Self.pendingManifestKey) else { return nil }
        return try? JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    private static func loadBundledReleaseNotes(from bundle: Bundle) -> ReleaseNotesDocument? {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ReleaseNotesDocument.self, from: data),
              (try? document.releaseNotes.validate()) != nil else { return nil }
        return document
    }

    private func notifyIfNeeded(for manifest: UpdateManifest) async {
        let notifiedBuildKey = "update.lastNotifiedBuild"
        guard userDefaults.integer(forKey: notifiedBuildKey) < manifest.build else { return }

        let center = UNUserNotificationCenter.current()
        do {
            var notificationSettings = await center.notificationSettings()
            if notificationSettings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                notificationSettings = await center.notificationSettings()
            }
            guard notificationSettings.authorizationStatus == .authorized
                    || notificationSettings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "A new usAIge version is available"
            content.body = "Version \(manifest.version) is ready. Open Settings to update."
            content.sound = .default
            content.categoryIdentifier = Self.notificationCategory
            content.userInfo = ["build": manifest.build]
            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifierPrefix + String(manifest.build),
                content: content,
                trigger: nil
            )
            try await center.add(request)
            userDefaults.set(manifest.build, forKey: notifiedBuildKey)
        } catch {
            // The Settings badge remains available when notifications are denied or unavailable.
        }
    }
}

actor UpdateInstaller {
    func download(manifest: UpdateManifest, using session: URLSession) async throws -> URL {
        let (temporaryURL, response) = try await Self.download(
            from: manifest.downloadURL,
            using: session
        )
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usaige-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        let dmgURL = workDirectory.appendingPathComponent("usAIge-\(manifest.version).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: dmgURL)

        let actualHash = try Self.sha256(of: dmgURL)
        guard actualHash.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: workDirectory)
            throw UpdateError.checksumMismatch
        }
        return dmgURL
    }

    func prepareAndLaunchReplacement(
        dmgURL: URL,
        manifest: UpdateManifest,
        currentApplicationURL: URL
    ) throws {
        guard currentApplicationURL.pathExtension == "app" else {
            throw UpdateError.notPackagedApplication
        }
        let parentURL = currentApplicationURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            throw UpdateError.applicationNotWritable
        }

        let attachData = try Self.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-plist", "-readonly", "-nobrowse", dmgURL.path]
        )
        let mountPoint = try Self.mountPoint(from: attachData)
        defer {
            _ = try? Self.run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])
        }

        let mountedApplicationURL = mountPoint.appendingPathComponent("usAIge.app")
        guard let updateBundle = Bundle(url: mountedApplicationURL),
              updateBundle.bundleIdentifier == "com.richardzhengquan.usaige",
              Int(updateBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                == manifest.build,
              updateBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == manifest.version else {
            throw UpdateError.invalidApplication
        }
        _ = try Self.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", mountedApplicationURL.path]
        )

        let workDirectory = dmgURL.deletingLastPathComponent()
        let stagedApplicationURL = workDirectory.appendingPathComponent("usAIge.app")
        _ = try Self.run(
            "/usr/bin/ditto",
            arguments: [mountedApplicationURL.path, stagedApplicationURL.path]
        )

        let helperScript = """
        set -euo pipefail
        pid="$1"
        source_app="$2"
        target_app="$3"
        work_dir="$4"
        incoming="${target_app}.update"
        backup="${target_app}.backup"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$incoming" "$backup"
        /usr/bin/ditto "$source_app" "$incoming"
        if [ -e "$target_app" ]; then /bin/mv "$target_app" "$backup"; fi
        if /bin/mv "$incoming" "$target_app"; then
            rm -rf "$backup" "$work_dir"
            /usr/bin/open "$target_app"
        else
            if [ -e "$backup" ]; then /bin/mv "$backup" "$target_app"; fi
            exit 1
        fi
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = [
            "-c", helperScript, "usaige-updater",
            String(ProcessInfo.processInfo.processIdentifier),
            stagedApplicationURL.path,
            currentApplicationURL.path,
            workDirectory.path,
        ]
        try helper.run()
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func download(from url: URL, using session: URLSession) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let location, let response {
                    continuation.resume(returning: (location, response))
                } else {
                    continuation.resume(throwing: UpdateError.downloadFailed)
                }
            }.resume()
        }
    }

    private static func mountPoint(from data: Data) throws -> URL {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(
                String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? "Update preparation failed."
            )
        }
        return outputData
    }
}

enum UpdateError: LocalizedError {
    case invalidManifest
    case feedUnavailable
    case downloadFailed
    case checksumMismatch
    case notPackagedApplication
    case applicationNotWritable
    case mountFailed
    case invalidApplication
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The update information is invalid."
        case .feedUnavailable:
            "Couldn’t check for updates."
        case .downloadFailed:
            "The update couldn’t be downloaded."
        case .checksumMismatch:
            "The downloaded update failed its security check."
        case .notPackagedApplication:
            "Software updates require the packaged app."
        case .applicationNotWritable:
            "usAIge can’t replace the installed app. Move it to a writable Applications folder."
        case .mountFailed:
            "The downloaded update couldn’t be opened."
        case .invalidApplication:
            "The downloaded app isn’t a valid usAIge update."
        case let .commandFailed(message):
            message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The update couldn’t be completed."
    }
}
