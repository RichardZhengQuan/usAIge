import Foundation
import Testing
@testable import UsageHUD

@Test func parsesOneStepConnectionLink() throws {
    let link = try RemoteToolConnectionLink.parse(
        "usaige://connect?name=Team%20Claude&endpoint=https%3A%2F%2Flimits.example.com%2Fusage&website=https%3A%2F%2Fclaude.ai&token=secret"
    )

    #expect(link.name == "Team Claude")
    #expect(link.endpoint.absoluteString == "https://limits.example.com/usage")
    #expect(link.webURL?.absoluteString == "https://claude.ai")
    #expect(link.token == "secret")
}

@Test func acceptsPublicHTTPSLimitURLAsSimpleConnection() throws {
    let link = try RemoteToolConnectionLink.parse("https://limits.example.com/usage")

    #expect(link.name == "limits.example.com")
    #expect(link.endpoint.absoluteString == "https://limits.example.com/usage")
    #expect(link.token == nil)
}

@Test func rejectsInsecureOrIncompleteConnectionLinks() {
    #expect(throws: RemoteToolConnectionLinkError.self) {
        try RemoteToolConnectionLink.parse("http://limits.example.com/usage")
    }
    #expect(throws: RemoteToolConnectionLinkError.self) {
        try RemoteToolConnectionLink.parse("usaige://connect?name=MissingEndpoint")
    }
}
