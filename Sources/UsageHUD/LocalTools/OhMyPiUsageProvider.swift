/// Reads upstream account limits from Oh My Pi's CLI JSON report.
/// The `omp usage --json` command was learned from ClaudeBar's Oh My Pi
/// provider (https://github.com/tddworks/ClaudeBar, Apache-2.0); this reader is usAIge's own.
import Foundation

private enum OhMyPiUsageParser {
    enum Reading {
        case signedOut
        case reconnect
        case limits([RateLimitBucket])
    }

    private struct Pool: Hashable {
        let meter: String?
        let modelTier: String?
        let sharedGroup: String?
    }

    private struct SharedWindow: Hashable {
        let group: String
        let id: String?
        let durationMs: Double?
    }

    private struct Window {
        let id: String?
        let label: String?
        let usedPercent: Double
        let durationMs: Double?
        let resetsAt: TimeInterval?
        let pool: Pool

        var poolOrder: (String, String, String, String, String) {
            (pool.modelTier ?? "", pool.sharedGroup ?? "", pool.meter ?? "", label ?? "", id ?? "")
        }

        var minutes: Int? {
            guard let durationMs, let minutes = Int(exactly: (durationMs / 60_000).rounded()),
                  minutes > 0 else { return nil }
            return minutes
        }

        // The window id can establish order even when omp leaves durationMs
        // absent (for example Kimi's weekly row). Only durationMs is displayed.
        var durationForOrdering: Double? {
            if let durationMs { return durationMs }
            switch id {
            case "5h", "limit_5h", "300time_unit_minute": return 18_000_000
            case "daily", "1d": return 86_400_000
            case "weekly", "7d", "limit_7d": return 604_800_000
            default: return nil
            }
        }
    }

    private static let providerNames = [
        "alibaba-token-plan": "Qwen Cloud",
        "anthropic": "Claude",
        "charm-hyper": "Charm Hyper",
        "cline-pass": "ClinePass",
        "commandcode": "Command Code",
        "cursor": "Cursor",
        "devin": "Devin",
        "factory-droid": "Factory Droid",
        "github-copilot": "Copilot",
        "google-antigravity": "Antigravity",
        "google-gemini-cli": "Gemini",
        "kimi-code": "Kimi",
        "minimax-code": "MiniMax",
        "minimax-code-cn": "MiniMax CN",
        "muse-code": "Muse Code",
        "ollama": "Ollama",
        "ollama-cloud": "Ollama Cloud",
        "openai-codex": "Codex",
        "opencode-go": "OpenCode Go",
        "synthetic": "Synthetic",
        "umans": "Umans",
        "xai-oauth": "Grok",
        "zai": "Z.ai",
    ]

    static func parse(_ data: Data) throws -> Reading {
        guard let payload = payload(from: data), let reports = payload["reports"]?.arrayValue else {
            throw LocalToolUsageError.invalidResponse
        }
        let hasAccountsWithoutUsage = try hasAccounts(in: payload["accountsWithoutUsage"])
        let hasSignedOutAccounts = try hasAccounts(in: payload["disabledCredentials"])
        var accountsPerProvider: [String: Int] = [:]
        var result: [RateLimitBucket] = []
        for report in reports {
            guard let provider = text(report["provider"])?.lowercased(),
                  let limits = report["limits"]?.arrayValue,
                  limits.allSatisfy({ $0.objectValue != nil }) else {
                throw LocalToolUsageError.invalidResponse
            }

            // Only known provider names enter public labels or ids.
            let providerKey = providerNames[provider] == nil ? "other" : provider.replacingOccurrences(of: "-", with: "_")
            let providerName = providerNames[provider] ?? "Other provider"
            accountsPerProvider[providerKey, default: 0] += 1
            let account = accountsPerProvider[providerKey, default: 0]
            let id = "\(AIToolID.ohMyPi.rawValue)_\(providerKey)_\(account)"
            let name = account == 1 ? providerName : "\(providerName) \(account)"
            let plan = text(report.value(at: ["metadata", "planType"]))
            let windows = windows(from: limits, provider: provider)
            result += buckets(from: windows, id: id, name: name, plan: plan)
        }
        if !result.isEmpty { return .limits(result) }
        if hasSignedOutAccounts { return .reconnect }
        return reports.isEmpty && !hasAccountsWithoutUsage ? .signedOut : .limits([])
    }

    private static func payload(from data: Data) -> JSONValue? {
        if let json = JSONValue.parse(data) { return json }
        // Some versions print status lines before or after the JSON.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("}") }),
              start <= end else { return nil }
        return JSONValue.parse(Data(lines[start...end].joined(separator: "\n").utf8))
    }

    private static func hasAccounts(in value: JSONValue?) throws -> Bool {
        guard let value, value != .null else { return false }
        guard let accounts = value.arrayValue, accounts.allSatisfy({ text($0["provider"]) != nil }) else {
            throw LocalToolUsageError.invalidResponse
        }
        return !accounts.isEmpty
    }

    private static func windows(from limits: [JSONValue], provider: String) -> [Window] {
        var seenSharedWindows: Set<SharedWindow> = []
        let measured: [Window] = limits.compactMap { limit in
            let scope = limit["scope"]
            let window = limit["window"]
            let id = text(scope?["windowId"]) ?? text(window?["id"])
            let unit = text(limit.value(at: ["amount", "unit"]))?.lowercased()
            guard let amount = limit["amount"], let used = usedPercent(of: amount, unit: unit) else { return nil }

            let durationMs = window?["durationMs"]?.lenientNumber.flatMap { $0 > 0 ? $0 : nil }
            let resetsAt = window?["resetsAt"]?.lenientNumber.flatMap { $0 >= 0 ? $0 / 1_000 : nil }
            let group = text(scope?["sharedGroup"])
            if let group {
                let key = SharedWindow(group: group, id: id, durationMs: id == nil ? durationMs : nil)
                guard seenSharedWindows.insert(key).inserted else { return nil }
            }

            return Window(
                id: id,
                label: text(limit["label"]),
                usedPercent: used,
                durationMs: durationMs,
                resetsAt: resetsAt,
                pool: Pool(
                    meter: unit == "percent" || unit == "unknown" ? nil : unit,
                    modelTier: group == nil ? text(scope?["tier"]) : nil,
                    sharedGroup: poolName(for: group, windowID: id)
                )
            )
        }

        // Kimi can repeat a weekly summary as an aggregate with a different
        // amount unit. Keep the aggregate when it is the only usable row.
        guard provider == "kimi-code" else { return measured }
        let ids = Set(measured.compactMap(\.id))
        return measured.filter { window in
            switch window.id {
            case "limit_5h": !ids.contains("5h")
            case "limit_7d": !ids.contains("7d")
            default: true
            }
        }
    }

    private static func poolName(for group: String?, windowID: String?) -> String? {
        // Antigravity includes the window id in shared-group names, such as
        // `3p-5h:5h` and `3p-weekly:weekly` for the same pool.
        guard let group, let windowID else { return group }
        let suffix = "-\(windowID):\(windowID)"
        return group.hasSuffix(suffix) ? String(group.dropLast(suffix.count)) : group
    }

    private static func usedPercent(of amount: JSONValue, unit: String?) -> Double? {
        let cap = amount["limit"]?.lenientNumber.flatMap { $0 > 0 ? $0 : nil }
        let measured = cap.flatMap { cap in
            amount["used"]?.lenientNumber.map { $0 / cap * 100 }
                ?? amount["remaining"]?.lenientNumber.map { (1 - $0 / cap) * 100 }
        }
        let fraction = amount["remainingFraction"]?.lenientNumber.map { (1 - $0) * 100 }
            ?? amount["usedFraction"]?.lenientNumber.map { $0 * 100 }
        if unit == "usd" { return cap == nil ? nil : measured ?? fraction }
        return fraction ?? measured
    }

    private static func buckets(from windows: [Window], id: String, name: String, plan: String?) -> [RateLimitBucket] {
        let groups = Dictionary(grouping: windows.indices) { windows[$0].pool }
        var pairs: [Int: Int] = [:]
        for (pool, group) in groups where pool.meter != "usd" || pool.sharedGroup != nil {
            // A matching label can disambiguate several model pools under the
            // same meter. Keep windows separate when the match is ambiguous.
            let candidates = group.count > 2 ? Array(Dictionary(grouping: group) { windows[$0].label }.values) : [group]
            for pair in candidates {
                guard pair.count == 2, let first = windows[pair[0]].durationForOrdering,
                      let second = windows[pair[1]].durationForOrdering, first != second else { continue }
                pairs[pair[0]] = pair[1]
            }
        }

        let paired = Set(pairs.values)
        // Base quotas come first. Named pools keep their numbers when omp
        // changes the order of limit rows within an account.
        let ordered = windows.indices.filter { !paired.contains($0) }.sorted {
            windows[$0].poolOrder < windows[$1].poolOrder
        }
        return ordered.enumerated().map { poolIndex, index in
            var primary = windows[index]
            var secondary = pairs[index].map { windows[$0] }
            if let companion = secondary,
               let first = primary.durationForOrdering, let second = companion.durationForOrdering, first > second {
                secondary = primary
                primary = companion
            }
            return RateLimitBucket(
                limitID: poolIndex == 0 ? id : "\(id)_pool_\(poolIndex + 1)",
                limitName: name,
                usedPercent: primary.usedPercent,
                windowDurationMinutes: primary.minutes,
                resetsAt: primary.resetsAt,
                planType: plan,
                secondaryUsedPercent: secondary?.usedPercent,
                secondaryWindowDurationMinutes: secondary?.minutes,
                secondaryResetsAt: secondary?.resetsAt
            )
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

actor OhMyPiUsageProvider: CodexUsageProviding {
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
            let (result, status) = try await read()
            await statusRegistry?.report(status, for: .ohMyPi)
            return result
        } catch {
            let failure = error as? LocalToolUsageError ?? .invalidResponse
            let status: LocalToolStatus = failure == .invalidResponse
                ? .failed("Run `omp usage` in Terminal to check the usage report.")
                : LocalToolStatus(error: failure)
            await statusRegistry?.report(status, for: .ohMyPi)
            if failure == .notInstalled || failure == .notSignedIn { return .signedOut }
            throw failure
        }
    }

    private func read() async throws -> (AccountUsageResult, LocalToolStatus) {
        guard let output = try await runner.run("omp", arguments: ["usage", "--json"], timeout: 30) else {
            return (.signedOut, .notInstalled)
        }
        guard output.exitCode == 0 else { throw LocalToolUsageError.invalidResponse }

        switch try OhMyPiUsageParser.parse(output.standardOutput) {
        case .signedOut:
            return (.signedOut, .signedOut)
        case .reconnect:
            return (.authenticated([]), .failed("Sign in again in Oh My Pi (`omp`)."))
        case let .limits(buckets):
            let updatedAt = now()
            let snapshots = buckets.map { bucket in
                var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
                snapshot.toolID = .ohMyPi
                return snapshot
            }
            return (.authenticated(snapshots), .connected)
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}
}
