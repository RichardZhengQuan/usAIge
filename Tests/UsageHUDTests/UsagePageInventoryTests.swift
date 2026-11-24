import Foundation
import Testing
@testable import UsageHUD

@Test func usageInventoryLooksForSoftwareEvenBeforeSignInAndIgnoresLeftoverData() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bin = home.appendingPathComponent("bin")
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    for command in ["claude", "cline", "gh"] {
        let path = bin.appendingPathComponent(command).path
        #expect(fm.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o755]))
    }
    // Generic GitHub CLI, saved auth folders and non-executable files do not
    // imply an installed AI product.
    try fm.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
    #expect(fm.createFile(atPath: bin.appendingPathComponent("omp").path, contents: Data(), attributes: [.posixPermissions: 0o644]))
    func installed() -> Set<AIToolID> {
        InstalledUsageTools.detected(applications: [.cursor], environment: ["HOME": home.path],
                                     applicationDirectories: [], commandDirectories: [bin])
    }
    #expect(installed() == [.claude, .cline, .cursor])
    let folder = home.appendingPathComponent(".vscode/extensions")
    let ext = folder.appendingPathComponent("github.copilot-chat-1.1.0")
    try fm.createDirectory(at: ext, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: ext.appendingPathComponent("package.json"))
    #expect(installed().contains(.copilot))
    try Data(#"{"github.copilot-chat-1.1.0":true}"#.utf8).write(to: folder.appendingPathComponent(".obsolete"))
    #expect(!installed().contains(.copilot))
    try fm.removeItem(at: bin.appendingPathComponent("claude"))
    #expect(!installed().contains(.claude))
    for id in ["openai.chatgpt", "anthropic.claude-code", "Google.geminicodeassist", "sst-dev.opencode"] {
        let extensionURL = home.appendingPathComponent(".cursor/extensions/\(id)-1.0.0-darwin-arm64")
        try fm.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extensionURL.appendingPathComponent("package.json"))
    }
    #expect(installed() == [.chatGPT, .claude, .gemini, .openCodeGo, .cline, .cursor])
}

@MainActor @Test func usageGroupsOnlyInstalledToolsByReadingsInTheirSavedOrder() throws {
    let suite = "usage.groups.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = HUDSettings(defaults: defaults)
    settings.toolOrder = [.grok, .cursor, .claude, .cursor]
    settings.bucketOrder = ["claude-weekly", "claude-session"]
    let weekly = inventoryReading(.claude, id: "claude-weekly")
    let session = inventoryReading(.claude, id: "claude-session")
    var snapshots = [session, weekly, inventoryReading(.grok), inventoryReading(.chatGPT),
                     inventoryReading(AIToolID(rawValue: "paired-tool"))]
    func sections() -> (withReadings: [ModernToolEntry], notConnected: [ModernToolEntry]) {
        ModernToolList.installedSections(installed: [.cursor, .copilot, .grok, .claude], snapshots: snapshots,
                                         settings: settings, editing: false,
                                         status: { $0 == .cursor ? .credentialExpired : .optInRequired })
    }
    let first = sections()
    #expect(first.withReadings.map(\.id) == [.grok, .claude])
    #expect(first.withReadings.last?.limits == [weekly, session])
    #expect(first.notConnected.map(\.id) == [.cursor, .copilot])
    #expect(first.notConnected.first?.status?.isProblem == true)
    #expect(first.notConnected.last?.status?.text.contains("Off") == true)

    snapshots.append(inventoryReading(.cursor))
    let signedIn = sections()
    #expect(signedIn.withReadings.map(\.id) == [.grok, .cursor, .claude])
    #expect(signedIn.notConnected.map(\.id) == [.copilot])
}

@MainActor @Test func usageEditIncludesHiddenInstalledToolsInTheirOriginalSection() throws {
    let suite = "usage.edit.groups.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = HUDSettings(defaults: defaults)
    settings.toolOrder = [.grok, .chatGPT, .cursor, .claude]
    settings.hiddenToolIDs = [.grok, .cursor]
    let claude = inventoryReading(.claude)
    settings.hiddenBucketIDs = [claude.id]
    let snapshots = [inventoryReading(.grok), claude, inventoryReading(.gemini)]
    func sections(editing: Bool) -> (withReadings: [ModernToolEntry], notConnected: [ModernToolEntry]) {
        ModernToolList.installedSections(installed: [.grok, .chatGPT, .cursor, .claude], snapshots: snapshots,
                                         settings: settings, editing: editing, status: { _ in .notInstalled })
    }
    let normal = sections(editing: false)
    #expect(normal.withReadings.map(\.id) == [.claude])
    #expect(normal.notConnected.map(\.id) == [.chatGPT])
    let editor = sections(editing: true)
    #expect(editor.withReadings.map(\.id) == [.grok, .claude])
    #expect(editor.notConnected.map(\.id) == [.chatGPT, .cursor])
    #expect(editor.notConnected.last?.status?.text.contains("Not connected") == true)
}

private func inventoryReading(_ tool: AIToolID, id: String? = nil) -> QuotaSnapshot {
    QuotaSnapshot(id: id ?? tool.rawValue, toolID: tool, displayName: "Weekly", usedPercent: 15,
                  remainingPercent: 85, resetAt: nil, windowDurationMinutes: 10080,
                  planType: nil, updatedAt: Date())
}

@Test func deviceDocksUseThePhonesReportedByTheRelayEvenForIdenticalNames() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    func device(_ id: String, parent: String? = nil) throws -> RelayPhoneDevice {
        var fields = ["id": id, "name": "Same name", "created_at": "2026-11-22T12:00:00Z",
                      "last_seen_at": "2026-11-23T12:00:00Z"]
        fields["parent_phone_id"] = parent
        return try decoder.decode(RelayPhoneDevice.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let phoneA = try device("56a4b1da-d236-4e5e-9e2f-51cfc63d62d9")
    let phoneB = try device("ba2956bc-077d-416b-82e8-d4d47fb3653c")
    let watchA = try device("bec4ab75-ad09-513a-9412-e2717d68f37c", parent: phoneA.id.uppercased())
    let secondWatch = try device("bd21296d-77ee-55a6-ab7f-2dffbddc4eeb", parent: phoneA.id)
    let legacyWatch = try device("7c2df876-8402-5c7d-a909-d6ac13135945")
    let orphan = try device("1277d3a9-da64-56bf-a863-5e56f4141aaa", parent: "revoked-phone")
    #expect(RelayDeviceDock.list([]).isEmpty)
    #expect(RelayDeviceDock.empty.missingPhoneText(isLinked: false) == "No iPhone paired")
    #expect(RelayDeviceDock.empty.missingPhoneText(isLinked: true) == "No iPhone reported")
    #expect(RelayDeviceDock(phone: nil, watch: legacyWatch).missingPhoneText(isLinked: true) == "Paired iPhone unknown")
    #expect(RelayDeviceDock(phone: nil, watch: orphan).missingPhoneText(isLinked: true) == "Paired iPhone no longer linked")
    let docks = RelayDeviceDock.list([watchA, legacyWatch, phoneB, phoneA, secondWatch, orphan])
    #expect(docks == [
        RelayDeviceDock(phone: phoneB, watch: nil),
        RelayDeviceDock(phone: phoneA, watch: watchA),
        RelayDeviceDock(phone: phoneA, watch: secondWatch),
        RelayDeviceDock(phone: nil, watch: legacyWatch),
        RelayDeviceDock(phone: nil, watch: orphan)
    ])
    #expect(Set(docks.map(\.id)).count == docks.count)
    let localDocks = RelayDeviceDock.list([phoneA, phoneB, legacyWatch, watchA, orphan],
        localPhones: [legacyWatch.id: phoneB.id, watchA.id: phoneB.id, orphan.id: phoneB.id])
    #expect(localDocks == [RelayDeviceDock(phone: phoneA, watch: watchA),
                           RelayDeviceDock(phone: phoneB, watch: legacyWatch),
                           RelayDeviceDock(phone: nil, watch: orphan)])
    #expect(RelayDeviceDock.list([legacyWatch], localPhones: [legacyWatch.id: phoneB.id])
        == [RelayDeviceDock(phone: nil, watch: legacyWatch)])
}
