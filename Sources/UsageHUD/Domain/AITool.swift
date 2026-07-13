import AppKit
import SwiftUI

enum AIToolID: String, CaseIterable, Codable, Identifiable, Sendable {
    case chatGPT
    case claude
    case gemini
    case cursor

    var id: String { rawValue }
}

struct AIToolDescriptor: Identifiable, Equatable, Sendable {
    let id: AIToolID
    let name: String
    let systemImage: String
    let bundleIdentifiers: [String]
    let webURL: URL?

    static let all: [Self] = [
        Self(
            id: .chatGPT,
            name: "ChatGPT",
            systemImage: "sparkles",
            bundleIdentifiers: ["com.openai.codex", "com.openai.chat"],
            webURL: URL(string: "https://chatgpt.com")
        ),
        Self(
            id: .claude,
            name: "Claude",
            systemImage: "brain.head.profile",
            bundleIdentifiers: ["com.anthropic.claudefordesktop"],
            webURL: URL(string: "https://claude.ai")
        ),
        Self(
            id: .gemini,
            name: "Gemini",
            systemImage: "diamond.fill",
            bundleIdentifiers: ["com.google.Gemini"],
            webURL: URL(string: "https://gemini.google.com")
        ),
        Self(
            id: .cursor,
            name: "Cursor",
            systemImage: "cursorarrow.rays",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            webURL: URL(string: "https://cursor.com")
        ),
    ]

    static func descriptor(for id: AIToolID) -> Self {
        all.first(where: { $0.id == id })!
    }
}

@MainActor
enum AIToolLauncher {
    static func applicationURL(for tool: AIToolDescriptor) -> URL? {
        tool.bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    static func isInstalled(_ tool: AIToolDescriptor) -> Bool {
        applicationURL(for: tool) != nil
    }

    static func open(_ tool: AIToolDescriptor) {
        if let applicationURL = applicationURL(for: tool) {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
        } else if let webURL = tool.webURL {
            NSWorkspace.shared.open(webURL)
        }
    }
}

struct AIToolIcon: View {
    let tool: AIToolDescriptor
    var size: CGFloat = 24

    private var monochromeImage: NSImage? {
        guard tool.id == .chatGPT,
              let applicationURL = AIToolLauncher.applicationURL(for: tool) else { return nil }
        let resources = applicationURL.appendingPathComponent("Contents/Resources")
        let candidates = ["chatgptTemplate@2x.png", "chatgptTemplate.png"]
        for name in candidates {
            let url = resources.appendingPathComponent(name)
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let monochromeImage {
                Image(nsImage: monochromeImage)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: tool.systemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
