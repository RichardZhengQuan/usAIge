import Foundation

struct RemoteAITool: Codable, Equatable, Identifiable, Sendable {
    let id: AIToolID
    var name: String
    var endpoint: URL
    var webURL: URL?
    var systemImage: String
    var isEnabled: Bool

    init(
        id: AIToolID = AIToolID(rawValue: UUID().uuidString.lowercased()),
        name: String,
        endpoint: URL,
        webURL: URL? = nil,
        systemImage: String = "cpu",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.webURL = webURL
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }
}
