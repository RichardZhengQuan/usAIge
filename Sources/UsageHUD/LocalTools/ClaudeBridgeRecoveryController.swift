import AppKit
import Darwin
import Foundation

/// Explicitly configured recovery for one established Claude collector.
/// Reads only our quota metadata and exact-session lifecycle markers. It
/// never reads credentials, sends a prompt, or starts a new Claude session.
actor ClaudeBridgeRecoveryMonitor {
    struct Configuration: Codable, Sendable {
        let schemaVersion: Int
        let desktopSessionID: String
        let enabled: Bool

        var isValid: Bool {
            schemaVersion == 1 && desktopSessionID.hasPrefix("local_")
                && UUID(uuidString: String(desktopSessionID.dropFirst(6))) != nil
        }
    }

    /// Also holds the Usage-page attempt record that shares navigation grace.
    let directory: URL
    private let lifecycleURL: URL
    private var policy: ClaudeBridgeRecoveryPolicy

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/usAIge/claude-usage")
        lifecycleURL = homeDirectory.appendingPathComponent("Library/Logs/Claude/main.log")
        let attemptURL = directory.appendingPathComponent("recovery-attempt.json")
        let attempt = Self.read(attemptURL, maximum: 4_096).flatMap {
            try? JSONDecoder().decode(ClaudeBridgeRecoveryAttempt.self, from: $0)
        }
        policy = ClaudeBridgeRecoveryPolicy(lastAttempt: attempt)
    }

    func recoveryURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) -> URL? {
        guard claudeIsRunning, isEnabled,
              let configData = Self.read(directory.appendingPathComponent("recovery.json"), maximum: 4_096),
              let config = try? JSONDecoder().decode(Configuration.self, from: configData),
              config.isValid, config.enabled,
              let lifecycle = Self.read(lifecycleURL, maximum: 256 * 1_024, tail: true),
              let event = ClaudeBridgeLifecycleParser.latestEvent(
                in: String(decoding: lifecycle, as: UTF8.self), sessionID: config.desktopSessionID
              ) else { return nil }
        let response = Self.read(directory.appendingPathComponent("response.json"), maximum: 256 * 1_024)
            .flatMap(JSONValue.parse)
        // A partial status write can hide a server retry deadline. Wait for
        // the next check instead of treating unreadable status as permission
        // to reopen the collector and reset its request backoff.
        guard let statusData = Self.read(directory.appendingPathComponent("status.json"), maximum: 4_096),
              let status = JSONValue.parse(statusData), status["schemaVersion"]?.numberValue == 1,
              let checkedAt = LocalToolDates.parse(status["checkedAt"]?.stringValue) else { return nil }
        var nextAttemptAt: Date?
        if let nextValue = status["nextAttemptAt"] {
            guard let next = LocalToolDates.parse(nextValue.stringValue) else { return nil }
            nextAttemptAt = next
        }
        let heartbeat = ClaudeBridgeRecoveryHeartbeat(
            observedAt: response?["schemaVersion"]?.lenientNumber == 1
                ? LocalToolDates.parse(response?["observedAt"]?.stringValue) : nil,
            checkedAt: checkedAt,
            nextAttemptAt: nextAttemptAt,
            state: status["state"]?.stringValue
        )
        guard policy.shouldRecover(sessionID: config.desktopSessionID, now: date, event: event,
                                   heartbeat: heartbeat, claudeIsRunning: claudeIsRunning,
                                   isEnabled: isEnabled),
              let attempt = policy.lastAttempt,
              let data = try? JSONEncoder().encode(attempt) else { return nil }
        // Persist before navigating, so an app restart cannot repeatedly
        // focus Claude for the same paused session.
        do { try data.write(to: directory.appendingPathComponent("recovery-attempt.json"), options: .atomic) }
        catch { return nil }
        var url = URLComponents()
        url.scheme = "claude"
        url.host = "code"
        url.path = "/continue"
        url.queryItems = [URLQueryItem(name: "session", value: config.desktopSessionID)]
        return url.url
    }

    static func read(_ url: URL, maximum: Int, tail: Bool = false) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              tail || info.st_size <= maximum else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let skipsPrefix = tail && info.st_size > maximum
        if skipsPrefix {
            do { try handle.seek(toOffset: UInt64(info.st_size) - UInt64(maximum)) }
            catch { return nil }
        }
        guard var data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        if skipsPrefix {
            guard let newline = data.firstIndex(of: 10) else { return nil }
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }
}

protocol ClaudeCodeRecoveryProviding: Sendable {
    func recoveryURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) async -> URL?
}

protocol ClaudeUsagePageProviding: Sendable {
    func usagePageURL(at date: Date, claudeIsRunning: Bool, isEnabled: Bool) async -> URL?
}

extension ClaudeBridgeRecoveryMonitor: ClaudeCodeRecoveryProviding {}
extension ClaudeUsagePageRefreshMonitor: ClaudeUsagePageProviding {}

/// Both routes bring Claude forward. Any navigation, including one recorded
/// before usAIge restarted, holds the other route back for a short grace.
struct ClaudeNavigationGrace: Sendable {
    static let interval: TimeInterval = 90
    static let attemptFiles = ["recovery-attempt.json", "usage-page-refresh.json"]

    private struct Attempt: Decodable {
        let attemptedAt: Date
    }

    let directory: URL

    /// Unreadable records are left to each route's own validation. A record
    /// dated after `date` holds both routes until the clock passes its grace.
    func permitsNavigation(at date: Date, lastNavigation: Date? = nil) -> Bool {
        let persisted = Self.attemptFiles.compactMap { name in
            ClaudeBridgeRecoveryMonitor.read(directory.appendingPathComponent(name), maximum: 4_096)
                .flatMap { try? JSONDecoder().decode(Attempt.self, from: $0).attemptedAt }
        }
        return ([lastNavigation].compactMap { $0 } + persisted).allSatisfy { attempted in
            !attempted.timeIntervalSince1970.isFinite || date >= attempted.addingTimeInterval(Self.interval)
        }
    }
}

/// One 30-second check for Claude's two automatic refresh routes: reopen an
/// established Code collector, otherwise ask Claude's own Usage page to
/// refresh. The Usage-page route needs no setup, extra sign-in, or Code engine.
@MainActor
final class ClaudeBridgeRecoveryController {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private let monitor: any ClaudeCodeRecoveryProviding
    private let pageMonitor: (any ClaudeUsagePageProviding)?
    private let grace: ClaudeNavigationGrace
    private let isEnabled: @MainActor () -> Bool
    private let isClaudeRunning: @MainActor () -> Bool
    private let openURL: @MainActor (URL) -> Void
    private let now: @MainActor () -> Date
    private var lastNavigation: Date?
    private var task: Task<Void, Never>?

    convenience init(monitor: ClaudeBridgeRecoveryMonitor = ClaudeBridgeRecoveryMonitor(),
                     pageMonitor: (any ClaudeUsagePageProviding)? = ClaudeUsagePageRefreshMonitor(),
                     isEnabled: @escaping @MainActor () -> Bool) {
        self.init(monitor: monitor, pageMonitor: pageMonitor,
                  grace: ClaudeNavigationGrace(directory: monitor.directory), isEnabled: isEnabled,
                  isClaudeRunning: Self.claudeIsRunning, openURL: Self.openInClaude, now: Date.init)
    }

    init(monitor: any ClaudeCodeRecoveryProviding,
         pageMonitor: (any ClaudeUsagePageProviding)?,
         grace: ClaudeNavigationGrace,
         isEnabled: @escaping @MainActor () -> Bool,
         isClaudeRunning: @escaping @MainActor () -> Bool,
         openURL: @escaping @MainActor (URL) -> Void,
         now: @escaping @MainActor () -> Date) {
        self.monitor = monitor
        self.pageMonitor = pageMonitor
        self.grace = grace
        self.isEnabled = isEnabled
        self.isClaudeRunning = isClaudeRunning
        self.openURL = openURL
        self.now = now
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                do { try await Task.sleep(nanoseconds: 30 * 1_000_000_000) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Code recovery wins; the Usage page is consulted only when no Code
    /// session needs reopening. Each route records its own attempt, so the
    /// grace check runs first and a held-back route never records one.
    func check() async {
        let date = now()
        guard isEnabled(), isClaudeRunning(),
              grace.permitsNavigation(at: date, lastNavigation: lastNavigation) else { return }
        if let url = await monitor.recoveryURL(at: date, claudeIsRunning: true, isEnabled: true) {
            navigate(to: url, at: date)
            return
        }
        guard let pageMonitor, !Task.isCancelled, isEnabled(), isClaudeRunning(),
              let url = await pageMonitor.usagePageURL(at: date, claudeIsRunning: true, isEnabled: true)
        else { return }
        navigate(to: url, at: date)
    }

    private func navigate(to url: URL, at date: Date) {
        // Hiding Claude in the rail or quitting Claude while a route was
        // deciding cancels the navigation.
        guard !Task.isCancelled, isEnabled(), isClaudeRunning() else { return }
        lastNavigation = date
        openURL(url)
    }

    private static func claudeIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    private static func openInClaude(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, _ in }
    }
}
