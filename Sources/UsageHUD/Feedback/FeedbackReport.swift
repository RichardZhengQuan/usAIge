import Foundation

struct FeedbackDraft {
    static let contentLimit = 4_000

    var content = ""

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool { !trimmedContent.isEmpty }
}

struct FeedbackSubmission: Encodable, Equatable, Sendable {
    let schemaVersion = 1
    let content: String
    let platform: String
    let systemVersion: String
    let architecture: String
    let locale: String
    let language: String
    let appVersion: String
    let appBuild: String
    let appBundleIdentifier: String
    let submittedAt: Date

    init(
        content: String,
        platform: String = "macOS",
        systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: String = FeedbackEnvironment.architecture,
        locale: String = Locale.current.identifier,
        language: String = Locale.preferredLanguages.first ?? "unknown",
        appVersion: String = FeedbackEnvironment.appVersion,
        appBuild: String = FeedbackEnvironment.appBuild,
        appBundleIdentifier: String = FeedbackEnvironment.appBundleIdentifier,
        submittedAt: Date = Date()
    ) {
        self.content = String(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(FeedbackDraft.contentLimit)
        )
        self.platform = platform
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.locale = locale
        self.language = language
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.appBundleIdentifier = appBundleIdentifier
        self.submittedAt = submittedAt
    }
}

struct FeedbackReceipt: Decodable, Equatable, Sendable {
    let id: String
    let receivedAt: Date
}

struct FeedbackClient: Sendable {
    static let productionURL = URL(
        string: "https://usaige-macos.richardqz.chatgpt.site/api/v1/feedback"
    )!

    let endpoint: URL
    let session: URLSession

    init(endpoint: URL = Self.productionURL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func submit(_ submission: FeedbackSubmission) async throws -> FeedbackReceipt {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(submission)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackSubmissionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = try? JSONDecoder().decode(FeedbackErrorResponse.self, from: data)
            throw FeedbackSubmissionError.server(serverMessage?.error ?? "Feedback could not be sent.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FeedbackReceipt.self, from: data)
    }
}

enum FeedbackSubmissionError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The feedback server returned an invalid response."
        case let .server(message): message
        }
    }
}

enum FeedbackEnvironment {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development build"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.richardzhengquan.usaige"
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private struct FeedbackErrorResponse: Decodable {
    let error: String
}
