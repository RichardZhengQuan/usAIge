import AppKit
import SwiftUI

struct AIToolID: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    var id: String { rawValue }

    static let chatGPT = Self(rawValue: "chatGPT")
    static let claude = Self(rawValue: "claude")
    static let gemini = Self(rawValue: "gemini")
    static let cursor = Self(rawValue: "cursor")
    static let builtInIDs: [Self] = [.chatGPT, .claude, .gemini, .cursor]

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
        all.first(where: { $0.id == id }) ?? Self(
            id: id,
            name: id.rawValue,
            systemImage: "cpu",
            bundleIdentifiers: [],
            webURL: nil
        )
    }

    static func descriptor(for snapshot: QuotaSnapshot) -> Self {
        let builtIn = descriptor(for: snapshot.toolID)
        return Self(
            id: snapshot.toolID,
            name: snapshot.toolName ?? builtIn.name,
            systemImage: snapshot.toolSystemImage ?? builtIn.systemImage,
            bundleIdentifiers: builtIn.bundleIdentifiers,
            webURL: snapshot.toolWebURL ?? builtIn.webURL
        )
    }
}

@MainActor
enum AIToolLauncher {
    static let codexBundleIdentifier = "com.openai.codex"
    static let codexWebsiteURL = URL(string: "https://chatgpt.com/codex/")!

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

    static func codexLaunchURL(applicationURL: URL?) -> URL {
        applicationURL ?? codexWebsiteURL
    }

    static func openCodex() {
        let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: codexBundleIdentifier
        )
        let launchURL = codexLaunchURL(applicationURL: applicationURL)
        guard applicationURL != nil else {
            NSWorkspace.shared.open(launchURL)
            return
        }
        NSWorkspace.shared.openApplication(at: launchURL, configuration: .init())
    }

    static func codexTaskURL(id: String) -> URL? {
        guard !id.isEmpty,
              let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "codex://threads/\(encodedID)")
    }

    static func openCodexTask(id: String) {
        guard let url = codexTaskURL(id: id) else { return }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { runningApplication, _ in
            guard let runningApplication else { return }
            Task { @MainActor in
                // The HUD is a non-activating panel, so usAIge may not be frontmost here.
                // Activating it first creates an asynchronous race that consumes the first
                // click. The user-initiated deep link already authorizes Codex activation.
                runningApplication.activate(options: [.activateAllWindows])
            }
        }
    }
}

struct AIToolIcon: View {
    let tool: AIToolDescriptor
    var size: CGFloat = 24
    var showsContrastHalo = false
    var contrastHaloColor: Color?

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
                    .foregroundColor(.primary)
            } else {
                Image(systemName: tool.systemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.22)
                    .foregroundColor(.primary)
            }
        }
        .frame(width: size, height: size)
        .background(contrastHalo)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var contrastHalo: some View {
        if showsContrastHalo {
            Circle()
                .fill(
                    (contrastHaloColor ?? Color(NSColor.windowBackgroundColor))
                        .opacity(0.38)
                )
                .frame(width: size + 4, height: size + 4)
                .blur(radius: 2)
                .accessibilityHidden(true)
        }
    }
}
