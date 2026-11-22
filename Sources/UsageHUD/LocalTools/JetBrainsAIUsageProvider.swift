import Foundation

/// The AI quota a JetBrains IDE saves in its own options folder after it asks
/// the JetBrains account for it: `options/AIAssistantQuotaManager2.xml` under
/// `~/Library/Application Support/JetBrains/<IDE>` (Android Studio keeps it
/// under `Google/<IDE>`). Every IDE of one account saves the same quota, so the
/// file changed last is the freshest reading.
///
/// usAIge reads the file only: no sign-in, no request, nothing written. The
/// location was learned from ClaudeBar's JetBrains AI provider documentation
/// (https://github.com/tddworks/ClaudeBar, Apache-2.0); the parsing is usAIge's own.
struct JetBrainsAIQuotaFile: Equatable, Sendable {
    let url: URL
    let modifiedAt: Date
}

protocol JetBrainsAIQuotaSource: Sendable {
    /// Whether any JetBrains IDE (or Android Studio) has an options folder here.
    func hasIDE() -> Bool
    /// The quota file changed last, or nil when no IDE has saved one.
    func latestQuotaFile() -> JetBrainsAIQuotaFile?
}

struct JetBrainsAIQuotaDirectory: JetBrainsAIQuotaSource {
    static let fileName = "AIAssistantQuotaManager2.xml"
    /// Vendor folders under Application Support that hold JetBrains-platform IDEs.
    static let vendorFolders = ["JetBrains", "Google"]

    let applicationSupport: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        applicationSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    func hasIDE() -> Bool {
        !ideFolders().isEmpty
    }

    func latestQuotaFile() -> JetBrainsAIQuotaFile? {
        let fileManager = FileManager.default
        return ideFolders()
            .compactMap { folder -> JetBrainsAIQuotaFile? in
                let url = folder.appendingPathComponent("options/\(Self.fileName)")
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date else { return nil }
                return JetBrainsAIQuotaFile(url: url, modifiedAt: modified)
            }
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    /// IDE folders that have an `options` folder, such as
    /// `JetBrains/IntelliJIdea2025.3` or `Google/AndroidStudio2025.1`.
    private func ideFolders() -> [URL] {
        let fileManager = FileManager.default
        return Self.vendorFolders.flatMap { vendor -> [URL] in
            let root = applicationSupport.appendingPathComponent(vendor, isDirectory: true)
            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return children.filter { folder in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(
                    atPath: folder.appendingPathComponent("options").path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
        }
    }
}

/// What the IDE recorded about the account's AI quota.
enum JetBrainsAIQuotaReading: Equatable, Sendable {
    /// Credits used of the period's allowance; the refill time and period
    /// length when the IDE saved them.
    case available(used: Double, maximum: Double, refillsAt: Date?, periodMinutes: Int?)
    /// The IDE has no quota for this account: not signed in to JetBrains AI,
    /// or no AI plan.
    case unknown
    /// The IDE tried to fetch the quota and failed.
    case error
}

enum JetBrainsAIQuotaParser {
    /// Reads `<option name="quotaInfo" value="…"/>` and
    /// `<option name="nextRefill" value="…"/>`, whose values are JSON stored as
    /// XML-escaped attribute text. Numbers arrive as strings.
    static func parse(_ data: Data) -> JetBrainsAIQuotaReading? {
        let options = OptionCollector.options(in: data)
        guard let info = options["quotaInfo"].flatMap({ JSONValue.parse(Data($0.utf8)) }),
              info.objectValue != nil else { return nil }

        switch info["type"]?.stringValue {
        case "Unknown": return .unknown
        case "Error": return .error
        default: break
        }
        guard let used = info["current"]?.lenientNumber,
              let maximum = info["maximum"]?.lenientNumber,
              maximum > 0, used >= 0 else { return nil }

        var refillsAt: Date?
        var periodMinutes: Int?
        if let refill = options["nextRefill"].flatMap({ JSONValue.parse(Data($0.utf8)) }),
           refill["type"]?.stringValue == "Known" {
            refillsAt = LocalToolDates.parse(refill["next"]?.stringValue)
            let duration = refill.value(at: ["tariff", "duration"])?.stringValue
                ?? refill["duration"]?.stringValue
            periodMinutes = duration.flatMap(isoDurationMinutes)
        }
        return .available(used: used, maximum: maximum, refillsAt: refillsAt, periodMinutes: periodMinutes)
    }

    /// `PT720H` → 43 200, `P30D` → 43 200, `PT90M` → 90. Years, months and
    /// weeks have no fixed length and are not guessed.
    static func isoDurationMinutes(_ text: String) -> Int? {
        let scanner = Scanner(string: text.uppercased())
        guard scanner.scanString("P") != nil else { return nil }
        var seconds = 0.0
        var inTime = false
        var sawComponent = false
        while !scanner.isAtEnd {
            if scanner.scanString("T") != nil {
                inTime = true
                continue
            }
            guard let value = scanner.scanDouble(), value >= 0,
                  let unit = scanner.scanCharacter() else { return nil }
            switch (unit, inTime) {
            case ("D", false): seconds += value * 86_400
            case ("H", true): seconds += value * 3_600
            case ("M", true): seconds += value * 60
            case ("S", true): seconds += value
            default: return nil
            }
            sawComponent = true
        }
        guard sawComponent, seconds >= 60 else { return nil }
        return Int((seconds / 60).rounded())
    }

    /// Collects every `<option name=… value=…>` inside the
    /// `AIAssistantQuotaManager2` component. `XMLParser` decodes the escaped
    /// attribute text (`&quot;`, `&#10;`) back into the JSON the IDE wrote.
    private final class OptionCollector: NSObject, XMLParserDelegate {
        private var options: [String: String] = [:]
        private var componentDepth = 0

        static func options(in data: Data) -> [String: String] {
            let collector = OptionCollector()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = collector
            parser.parse()
            return collector.options
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            if elementName == "component" {
                if componentDepth > 0 || attributes["name"] == "AIAssistantQuotaManager2" {
                    componentDepth += 1
                }
                return
            }
            guard componentDepth > 0, elementName == "option",
                  let name = attributes["name"], let value = attributes["value"],
                  options[name] == nil else { return }
            options[name] = value
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if elementName == "component", componentDepth > 0 { componentDepth -= 1 }
        }
    }
}

/// JetBrains AI credits for the current period, read from the quota the
/// user's JetBrains IDE saved on this Mac. A passive local read: it never
/// touches a JetBrains sign-in and makes no request, so it runs on every
/// automatic tick.
actor JetBrainsAIUsageProvider: CodexUsageProviding, LocalUsageProviding {
    static let bucketID = "jetbrains_ai"
    /// Larger than any quota file an IDE writes; anything bigger is not one.
    static let maximumFileBytes = 1024 * 1024

    private let source: any JetBrainsAIQuotaSource
    private let statusRegistry: LocalToolStatusRegistry?
    private let now: @Sendable () -> Date

    init(
        source: any JetBrainsAIQuotaSource = JetBrainsAIQuotaDirectory(),
        statusRegistry: LocalToolStatusRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.statusRegistry = statusRegistry
        self.now = now
    }

    func refresh() async throws -> AccountUsageResult {
        do {
            let (result, status) = try read()
            await report(status)
            return result
        } catch {
            // An unreadable or half-written file keeps the last reading.
            await report(.failed("Couldn't read the quota your JetBrains IDE saved."))
            throw error
        }
    }

    func refreshLocalUsage() async -> AccountUsageResult? {
        try? await refresh()
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func stop() async {}

    private func read() throws -> (AccountUsageResult, LocalToolStatus) {
        guard let file = source.latestQuotaFile() else {
            return (.signedOut, source.hasIDE() ? .signedOut : .notInstalled)
        }
        guard let data = Self.contents(of: file.url),
              let reading = JetBrainsAIQuotaParser.parse(data) else {
            throw LocalToolUsageError.invalidResponse
        }
        switch reading {
        case .unknown:
            return (.signedOut, .signedOut)
        case .error:
            return (
                .authenticated([]),
                .failed("Your JetBrains IDE couldn't get the AI quota. Open AI Assistant in the IDE to try again.")
            )
        case let .available(used, maximum, refillsAt, periodMinutes):
            let current = now()
            // The IDE saves the quota only when it asks for it. Once the refill
            // time has passed, the saved figure belongs to a period that has
            // ended, so it is left out rather than shown as current.
            if let refillsAt, refillsAt <= current {
                return (
                    .authenticated([]),
                    .failed("The AI credits have refilled since your JetBrains IDE saved them. Open AI Assistant in the IDE to update.")
                )
            }
            let bucket = RateLimitBucket(
                limitID: Self.bucketID,
                limitName: "AI credits",
                usedPercent: min(100, max(0, used / maximum * 100)),
                windowDurationMinutes: periodMinutes,
                resetsAt: refillsAt?.timeIntervalSince1970,
                planType: nil
            )
            var snapshot = QuotaSnapshot.make(from: bucket, updatedAt: file.modifiedAt)
            snapshot.toolID = .jetBrainsAI
            return (.authenticated([snapshot]), .connected)
        }
    }

    private static func contents(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1),
              data.count <= maximumFileBytes else { return nil }
        return data
    }

    private func report(_ status: LocalToolStatus) async {
        guard let statusRegistry else { return }
        await statusRegistry.report(status, for: .jetBrainsAI)
    }
}
