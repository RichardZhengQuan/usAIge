import Foundation

/// A user-configured endpoint that exposes one or more AI quota windows.
public struct RemoteToolConfiguration: Codable, Hashable, Identifiable, Sendable {
    public static let allowedRefreshIntervalMinutes = 1...10_080

    public var id: UUID
    public var name: String
    public var endpointURL: URL
    public var refreshIntervalMinutes: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        endpointURL: URL,
        refreshIntervalMinutes: Int = 15,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.refreshIntervalMinutes = min(
            Self.allowedRefreshIntervalMinutes.upperBound,
            max(Self.allowedRefreshIntervalMinutes.lowerBound, refreshIntervalMinutes)
        )
        self.isEnabled = isEnabled
    }

    /// A suitable SF Symbol for common AI tools, with a neutral fallback.
    public var symbolName: String {
        let normalizedName = name.lowercased()
        if normalizedName.contains("chatgpt")
            || normalizedName.contains("openai")
            || normalizedName.contains("codex") {
            return "sparkles"
        }
        if normalizedName.contains("claude") || normalizedName.contains("anthropic") {
            return "brain.head.profile"
        }
        if normalizedName.contains("gemini") || normalizedName.contains("google") {
            return "diamond.fill"
        }
        if normalizedName.contains("cursor") {
            return "cursorarrow.rays"
        }
        return "cpu"
    }

    public var refreshInterval: TimeInterval {
        let minutes = min(
            Self.allowedRefreshIntervalMinutes.upperBound,
            max(Self.allowedRefreshIntervalMinutes.lowerBound, refreshIntervalMinutes)
        )
        return TimeInterval(minutes * 60)
    }

    /// Endpoint credentials belong in Keychain-backed bearer auth, never in a URL.
    public static func isSupportedEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host != nil
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    /// Redacts credential-like URL components from records created by older builds.
    public var displayEndpoint: String {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return endpointURL.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? endpointURL.host ?? "HTTPS endpoint"
    }
}
