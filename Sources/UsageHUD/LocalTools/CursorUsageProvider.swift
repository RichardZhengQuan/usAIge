import Foundation
import SQLite3

struct CursorSession: Equatable, Sendable {
    let accessToken: String
    let membershipType: String?
    let expiresAt: Date?
}

protocol CursorSessionSource: Sendable {
    /// `nil` means Cursor is not installed or not signed in on this Mac.
    func load() throws -> CursorSession?
}

/// Reads the live session token Cursor keeps in its own state store
/// (`state.vscdb`), the same value the editor sends to `api2.cursor.sh`.
/// The database is opened read-only and only two keys are read.
struct CursorStateDatabase: CursorSessionSource {
    static let accessTokenKey = "cursorAuth/accessToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"

    let databaseURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        databaseURL = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func load() throws -> CursorSession? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let token = try readValue(forKey: Self.accessTokenKey), !token.isEmpty else { return nil }
        let membership = try? readValue(forKey: Self.membershipTypeKey)
        return CursorSession(
            accessToken: token,
            membershipType: membership.flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: JSONWebToken.expiry(of: token)
        )
    }

    func readValue(forKey key: String) throws -> String? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let path = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        // Prefer a normal read-only open, which respects Cursor's WAL; fall back
        // to an immutable open if the journal is locked.
        for uri in ["file:\(path)?mode=ro", "file:\(path)?immutable=1"] {
            guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
                if database != nil { sqlite3_close(database) }
                database = nil
                continue
            }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw LocalToolUsageError.invalidResponse
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        throw LocalToolUsageError.invalidResponse
    }
}

actor CursorUsageProvider: CodexUsageProviding {
    static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    static let primaryBucketID = "cursor"

    private let session: any CursorSessionSource
    private let http: any UsageHTTPClient
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        session: any CursorSessionSource = CursorStateDatabase(),
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.http = http
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            let result = try await performRefresh()
            await report(result == .signedOut ? .signedOut : .connected)
            return result
        } catch {
            await report(LocalToolStatus(error: error))
            throw error
        }
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func performRefresh() async throws -> AccountUsageResult {
        guard let session = try session.load() else { return .signedOut }
        if let expiresAt = session.expiresAt, now() >= expiresAt {
            throw LocalToolUsageError.credentialExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        // Connect RPC over JSON; without this header the server answers with a
        // protobuf frame instead.
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsAIgeUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)

        let (status, body) = try await http.send(request)
        switch status {
        case 200..<300: break
        case 401, 403: throw LocalToolUsageError.credentialExpired
        case 429: throw LocalToolUsageError.rateLimited
        default: throw LocalToolUsageError.http(status)
        }
        guard let response = JSONValue.parse(body), response.objectValue != nil else {
            throw LocalToolUsageError.invalidResponse
        }
        return .authenticated(Self.snapshots(
            from: response,
            planType: session.membershipType,
            updatedAt: now()
        ))
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .cursor)
    }

    // MARK: Decoding

    /// Mirrors Cursor's Plan & Usage page: one bucket per model pool when the
    /// split is reported, otherwise the blended included-usage percentage.
    /// Money fields are minor units and int64 values arrive as strings.
    static func snapshots(from response: JSONValue, planType: String?, updatedAt: Date) -> [QuotaSnapshot] {
        guard let plan = response["planUsage"], plan.objectValue != nil else { return [] }
        let cycleStart = LocalToolDates.parseFlexible(response["billingCycleStart"])
        let cycleEnd = LocalToolDates.parseFlexible(response["billingCycleEnd"])
        let windowMinutes = LocalToolDates.windowMinutes(from: cycleStart, to: cycleEnd) ?? 43_200
        let resetsAt = cycleEnd?.timeIntervalSince1970

        func bucket(id: String, name: String, usedPercent: Double) -> RateLimitBucket {
            RateLimitBucket(
                limitID: id,
                limitName: name,
                usedPercent: min(100, max(0, usedPercent)),
                windowDurationMinutes: windowMinutes,
                resetsAt: resetsAt,
                planType: planType
            )
        }

        var buckets: [RateLimitBucket] = []
        if let auto = plan["autoPercentUsed"]?.lenientNumber {
            buckets.append(bucket(id: primaryBucketID, name: "Cursor models", usedPercent: auto))
        }
        if let api = plan["apiPercentUsed"]?.lenientNumber {
            buckets.append(bucket(id: "cursor_other", name: "Other models", usedPercent: api))
        }

        if buckets.isEmpty {
            let total: Double? = plan["totalPercentUsed"]?.lenientNumber ?? {
                guard let limit = plan["limit"]?.lenientNumber, limit > 0 else { return nil }
                let used = plan["used"]?.lenientNumber
                    ?? plan["remaining"]?.lenientNumber.map { limit - $0 }
                guard let used else { return nil }
                return used / limit * 100
            }()
            if let total {
                buckets.append(bucket(id: primaryBucketID, name: "Included usage", usedPercent: total))
            }
        }

        return buckets.map { bucket in
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: updatedAt)
            snapshot.toolID = .cursor
            return snapshot
        }
    }
}
