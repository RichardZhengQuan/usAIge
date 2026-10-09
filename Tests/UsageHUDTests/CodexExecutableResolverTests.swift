import Foundation
import Testing
@testable import UsageHUD

private func makeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func temporaryApplications() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-codex-apps-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func codexResolverFindsTheChatGPTAppsPackagedCLI() throws {
    let applications = try temporaryApplications()
    defer { try? FileManager.default.removeItem(at: applications) }
    let package = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli")
    try makeExecutable(at: package.appendingPathComponent("bin/codex"))
    try Data(#"{"layoutVersion":1,"entrypoint":"bin/codex"}"#.utf8)
        .write(to: package.appendingPathComponent("codex-package.json"))

    let resolved = CodexExecutableResolver.resolve(environment: ["PATH": ""], applicationDirectories: [applications])

    #expect(resolved?.standardizedFileURL == package.appendingPathComponent("bin/codex").standardizedFileURL)
}

@Test func codexResolverFollowsThePackageEntrypoint() throws {
    let applications = try temporaryApplications()
    defer { try? FileManager.default.removeItem(at: applications) }
    let package = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli")
    let entrypoint = package.appendingPathComponent("CodexCLI.app/Contents/MacOS/codex")
    try makeExecutable(at: entrypoint)
    try makeExecutable(at: package.appendingPathComponent("bin/codex"))
    try Data(#"{"entrypoint":"CodexCLI.app/Contents/MacOS/codex"}"#.utf8)
        .write(to: package.appendingPathComponent("codex-package.json"))

    let resolved = CodexExecutableResolver.resolve(environment: ["PATH": ""], applicationDirectories: [applications])

    #expect(resolved?.standardizedFileURL == entrypoint.standardizedFileURL)
}

@Test func codexResolverIgnoresAnEntrypointOutsideThePackage() throws {
    let applications = try temporaryApplications()
    defer { try? FileManager.default.removeItem(at: applications) }
    let package = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try makeExecutable(at: applications.appendingPathComponent("outside"))
    try Data(#"{"entrypoint":"../../../../outside"}"#.utf8)
        .write(to: package.appendingPathComponent("codex-package.json"))

    #expect(CodexExecutableResolver.packageEntrypoint(in: package, fileManager: .default) == nil)
    let resolved = CodexExecutableResolver.resolve(environment: ["PATH": ""], applicationDirectories: [applications])
    #expect(resolved?.lastPathComponent != "outside")
}

@Test func codexResolverStillFindsTheOlderBareBinary() throws {
    let applications = try temporaryApplications()
    defer { try? FileManager.default.removeItem(at: applications) }
    let legacy = applications.appendingPathComponent("Codex.app/Contents/Resources/codex")
    try makeExecutable(at: legacy)

    let resolved = CodexExecutableResolver.resolve(environment: ["PATH": ""], applicationDirectories: [applications])

    #expect(resolved?.standardizedFileURL == legacy.standardizedFileURL)
}

@Test func codexResolverSearchesThePersonalApplicationsFolder() {
    let directories = CodexExecutableResolver.defaultApplicationDirectories(environment: ["HOME": "/Users/someone"])
    #expect(directories.map(\.path) == ["/Applications", "/Users/someone/Applications"])
}
