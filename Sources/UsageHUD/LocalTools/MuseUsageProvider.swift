/// Reads Muse Code's subscription allowance from its CLI's JSON report.
/// The `muse usage --json` command was learned from ClaudeBar's Muse Code
/// provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Foundation

private enum MuseUsageParser {
    enum SchemaError: Error {
        case unsupportedVersion
    }

    private struct Window {
        let usedPercent: Double
        let minutes: Int?
        let resetsAt: TimeInterval?
    }

    static func bucket(from data: Data) throws -> RateLimitBucket {
        guard let payload = JSONValue.parse(data), let version = payload["schemaVersion"] else {
            throw LocalToolUsageError.invalidResponse
        }
        guard version == .number(1) else { throw SchemaError.unsupportedVersion }

        guard let allowance = payload["allowance"], allowance != .null else {
            if isSignInFailure(payload["reason"]?.stringValue) {
                throw LocalToolUsageError.credentialExpired
            }
            throw LocalToolUsageError.invalidResponse
        }

        // The session length is unspecified. `asOfMs` describes capture time;
        // the CLI does not give an expiry rule for the report.
        let session = try window(from: allowance["window"], minutes: nil)
        let weekly = try window(from: allowance["weekly"], minutes: 10_080)
        guard let primary = session ?? weekly else { throw LocalToolUsageError.invalidResponse }
        let secondary = session == nil ? nil : weekly
        let tier = allowance["tier"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        return RateLimitBucket(
            limitID: AIToolID.muse.rawValue,
            limitName: "Muse Code",
            usedPercent: primary.usedPercent,
            windowDurationMinutes: primary.minutes,
            resetsAt: primary.resetsAt,
            planType: tier.flatMap { $0.isEmpty ? nil : $0 },
            secondaryUsedPercent: secondary?.usedPercent,
            secondaryWindowDurationMinutes: secondary?.minutes,
            secondaryResetsAt: secondary?.resetsAt
        )
    }

    private static func window(from value: JSONValue?, minutes: Int?) throws -> Window? {
        guard let value, value != .null else { return nil }
        guard let used = value["usedPercent"]?.numberValue, used.isFinite else {
            throw LocalToolUsageError.invalidResponse
        }

        var resetsAt: TimeInterval?
        if let reset = value["resetsAtMs"], reset != .null {
            guard let milliseconds = reset.numberValue, milliseconds.isFinite, milliseconds >= 0 else {
                throw LocalToolUsageError.invalidResponse
            }
            resetsAt = milliseconds / 1_000
        }
        return Window(usedPercent: used, minutes: minutes, resetsAt: resetsAt)
    }

    private static func isSignInFailure(_ reason: String?) -> Bool {
        guard let reason else { return false }
        let words = reason.lowercased().split { $0 == "_" || $0 == "-" || $0.isWhitespace }
        switch words.joined(separator: " ") {
        case "not logged in", "not authenticated", "authentication required", "login required", "session expired":
            return true
        default:
            return false
        }
    }
}

actor MuseUsageProvider: CodexUsageProviding {
    private let runner: any LocalCommandRunning
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        runner: any LocalCommandRunning = LocalCommandRunner(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            guard let output = try await runner.run("muse", arguments: ["usage", "--json"], timeout: 30) else {
                await statusRegistry?.report(.notInstalled, for: .muse)
                return .signedOut
            }
            // A failed command can still print a structured sign-in error.
            let bucket = try MuseUsageParser.bucket(from: output.standardOutput)
            guard output.exitCode == 0 else { throw LocalToolUsageError.invalidResponse }

            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: now())
            snapshot.toolID = .muse
            await statusRegistry?.report(.connected, for: .muse)
            return .authenticated([snapshot])
        } catch MuseUsageParser.SchemaError.unsupportedVersion {
            await statusRegistry?.report(.failed("Update Muse Code; usAIge can't read this version's usage."), for: .muse)
            throw LocalToolUsageError.invalidResponse
        } catch {
            let failure = error as? LocalToolUsageError ?? .invalidResponse
            let status: LocalToolStatus = failure == .invalidResponse
                ? .failed("Run `muse usage` in Terminal to check your allowance.")
                : LocalToolStatus(error: failure)
            await statusRegistry?.report(status, for: .muse)
            if failure == .notInstalled || failure == .notSignedIn { return .signedOut }
            throw failure
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}
