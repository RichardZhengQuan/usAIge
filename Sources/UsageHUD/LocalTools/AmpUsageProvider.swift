/// Reads Amp credit balances from the signed-in CLI's `amp usage --no-color` output.
/// The command was learned from ClaudeBar's Amp provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.

import Foundation

enum AmpUsageParser {
    private static let ansi = #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B\r\n]*(?:\x07|\x1B\\))"#
    private static let creditLine = try! NSRegularExpression(
        pattern: #"^(.+?):\s*\$\s*(-?[0-9]+(?:\.[0-9]+)?)(?:\s*/\s*\$\s*([0-9]+(?:\.[0-9]+)?))?\s+remaining\b"#,
        options: .caseInsensitive
    )

    /// Nil means no credit report was recognized. A report with only dollar
    /// balances is valid but has no percentage buckets.
    static func buckets(from output: String) -> [RateLimitBucket]? {
        let plain = output.replacingOccurrences(of: ansi, with: "", options: .regularExpression)
        var sawCredit = false
        var buckets: [RateLimitBucket] = []
        var occurrences: [String: Int] = [:]

        for rawLine in plain.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let match = creditLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let amountRange = Range(match.range(at: 2), in: line),
                  let remaining = Double(line[amountRange]), remaining.isFinite else { continue }

            let reportedName = line[nameRange].trimmingCharacters(in: .whitespaces)
            guard !reportedName.isEmpty else { continue }
            guard let limitRange = Range(match.range(at: 3), in: line) else {
                sawCredit = true
                continue
            }
            guard let limit = Double(line[limitRange]), limit.isFinite, limit > 0 else { continue }
            sawCredit = true

            let normalized = reportedName.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let isFree = normalized == "free" || normalized == "amp free"
            let slug = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
            let baseID = isFree ? AIToolID.amp.rawValue : "amp_\(slug.isEmpty ? "credits" : slug)"
            let occurrence = occurrences[baseID, default: 0] + 1
            occurrences[baseID] = occurrence
            // The double underscore keeps duplicate slugs distinct from names ending in a number.
            let id = occurrence == 1 ? baseID : "\(baseID)__\(occurrence)"

            buckets.append(RateLimitBucket(
                limitID: id,
                limitName: isFree ? "Free" : reportedName,
                usedPercent: min(100, max(0, (limit - remaining) / limit * 100)),
                windowDurationMinutes: nil,
                resetsAt: nil,
                planType: nil
            ))
        }
        return sawCredit ? buckets : nil
    }
}

actor AmpUsageProvider: CodexUsageProviding {
    private let command: any LocalCommandRunning
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        command: any LocalCommandRunning = LocalCommandRunner(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.command = command
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        let output: LocalCommandOutput?
        do {
            output = try await command.run("amp", arguments: ["usage", "--no-color"], timeout: 10)
        } catch {
            let failure = error as? LocalToolUsageError ?? .invalidResponse
            await report(LocalToolStatus(error: failure))
            if error is CancellationError { throw error }
            if failure == .notInstalled || failure == .notSignedIn { return .signedOut }
            throw failure
        }

        guard let output else {
            await report(.notInstalled)
            return .signedOut
        }
        guard output.exitCode == 0 else {
            await report(.failed("`amp usage` failed. Run it in Terminal to see why."))
            throw LocalToolUsageError.invalidResponse
        }
        guard let buckets = AmpUsageParser.buckets(from: output.text) else {
            await report(.failed("Couldn't find Amp credit lines. Sign in with `amp login`, or update usAIge."))
            throw LocalToolUsageError.invalidResponse
        }

        let updatedAt = now()
        let snapshots = buckets.map { bucket in
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
            snapshot.toolID = .amp
            return snapshot
        }
        await report(.connected)
        return .authenticated(snapshots)
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func report(_ status: LocalToolStatus) async {
        await statusRegistry?.report(status, for: .amp)
    }
}
