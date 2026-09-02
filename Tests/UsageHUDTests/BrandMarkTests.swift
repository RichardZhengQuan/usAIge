import AppKit
import Foundation
import SwiftUI
import Testing
@testable import UsageHUD

@Test func everyBuiltInToolHasABrandMarkAndTemplateCandidatesWhereAppsShipThem() {
    for id in [AIToolID.claude, .cursor, .grok, .gemini] {
        #expect(BrandMark.hasMark(for: id))
    }
    #expect(!BrandMark.hasMark(for: .chatGPT))
    #expect(!BrandMark.hasMark(for: AIToolID(rawValue: "remote-tool")))
    #expect(AIToolIcon.templateIconCandidates(for: .chatGPT) == ["chatgptTemplate@2x.png", "chatgptTemplate.png"])
    #expect(AIToolIcon.templateIconCandidates(for: .claude) == ["TrayIconTemplate@2x.png", "TrayIconTemplate.png"])
    #expect(AIToolIcon.templateIconCandidates(for: .cursor).isEmpty)
    #expect(AIToolIcon.templateIconCandidates(for: .grok).isEmpty)
}

@Test func bundledToolMarksShipForClaudeCursorAndGrok() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let marks = repoRoot.appendingPathComponent("Sources/UsageHUD/Resources/ToolMarks")
    let environment = [BundledToolMark.environmentKey: marks.path]

    for id in [AIToolID.claude, .cursor, .grok] {
        let url = try #require(BundledToolMark.url(for: id, environment: environment))
        let image = try #require(NSImage(contentsOf: url))
        #expect(image.size.width > 0 && image.size.height > 0)
    }
    #expect(BundledToolMark.fileName(for: .chatGPT) == nil)
    #expect(BundledToolMark.url(for: .claude, environment: [:], bundle: Bundle(for: LocalToolTestAnchor.self)) == nil)
    #expect(BundledToolMark.searchDirectories(environment: environment, bundle: .main).first?.path == marks.path)
}

private final class LocalToolTestAnchor {}

/// Opt-in: renders every tool icon to PNG for a visual check.
///   USAIGE_RENDER_ICONS=/path/to/dir swift test --filter rendersBrandMarks
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["USAIGE_RENDER_ICONS"] != nil))
func rendersBrandMarksToPNG() throws {
    guard #available(macOS 13.0, *) else { return }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["USAIGE_RENDER_ICONS"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for id in AIToolID.builtInIDs {
        for (variant, view) in [
            ("icon", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 64).padding(8).background(Color.white))),
            ("mark", AnyView(BrandMarkView(toolID: id).frame(width: 64, height: 64).padding(8).foregroundColor(.black).background(Color.white))),
            ("dark", AnyView(AIToolIcon(tool: .descriptor(for: id), size: 64).padding(8).background(Color.black).environment(\.colorScheme, .dark))),
        ] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(id.rawValue)-\(variant).png"))
        }
    }
}
