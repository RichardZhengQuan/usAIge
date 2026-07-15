import Foundation

struct RemoteToolConnectionLink: Equatable, Sendable {
    let name: String
    let endpoint: URL
    let webURL: URL?
    let token: String?

    static func parse(_ text: String) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw RemoteToolConnectionLinkError.invalidLink }

        if url.scheme?.lowercased() == "https" {
            guard let host = url.host, !host.isEmpty else {
                throw RemoteToolConnectionLinkError.invalidLink
            }
            return Self(name: host, endpoint: url, webURL: nil, token: nil)
        }

        guard url.scheme?.lowercased() == "usaige",
              url.host?.lowercased() == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RemoteToolConnectionLinkError.invalidLink
        }
        let values = Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard let name = values["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let endpointText = values["endpoint"],
              let endpoint = URL(string: endpointText),
              endpoint.scheme?.lowercased() == "https",
              endpoint.host != nil else {
            throw RemoteToolConnectionLinkError.invalidLink
        }
        let webURL = values["website"].flatMap(URL.init(string:))
        if let webURL, !["http", "https"].contains(webURL.scheme?.lowercased() ?? "") {
            throw RemoteToolConnectionLinkError.invalidLink
        }
        return Self(
            name: name,
            endpoint: endpoint,
            webURL: webURL,
            token: values["token"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

enum RemoteToolConnectionLinkError: LocalizedError {
    case invalidLink

    var errorDescription: String? {
        "That connection link is not valid. Ask its provider for a new usAIge link."
    }
}
