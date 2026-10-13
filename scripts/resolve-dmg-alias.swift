#!/usr/bin/env swift
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: resolve-dmg-alias.swift <Applications alias>\n".utf8))
    exit(2)
}

do {
    let alias = URL(fileURLWithPath: CommandLine.arguments[1])
    let target = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
    guard target.standardizedFileURL.path == "/Applications" else {
        throw NSError(domain: "usAIge.DMG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Installer alias does not point to /Applications"])
    }
    print("/Applications/")
} catch {
    FileHandle.standardError.write(Data("Cannot validate installer alias: \(error.localizedDescription)\n".utf8))
    exit(1)
}
