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
    static let grok = Self(rawValue: "grok")
    static let jetBrainsAI = Self(rawValue: "jetbrainsAI")
    static let windsurf = Self(rawValue: "windsurf")
    static let antigravity = Self(rawValue: "antigravity")
    static let copilot = Self(rawValue: "copilot")
    static let kiro = Self(rawValue: "kiro")
    static let amp = Self(rawValue: "amp")
    static let muse = Self(rawValue: "muse")
    static let ohMyPi = Self(rawValue: "ohMyPi")
    static let commandCode = Self(rawValue: "commandCode")
    static let cline = Self(rawValue: "cline")
    static let openCodeGo = Self(rawValue: "openCodeGo")
    static let builtInIDs: [Self] = [
        .chatGPT, .claude, .gemini, .cursor, .grok, .jetBrainsAI, .windsurf,
        .antigravity, .copilot, .kiro, .amp, .muse, .ohMyPi, .commandCode, .cline, .openCodeGo,
    ]

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
        Self(
            id: .grok,
            name: "Grok Build",
            systemImage: "line.diagonal",
            bundleIdentifiers: ["ai.x.grok"],
            webURL: URL(string: "https://grok.com")
        ),
        Self(
            id: .jetBrainsAI,
            name: "JetBrains AI",
            systemImage: "j.square",
            // Opening the tool opens the first JetBrains IDE found, since the
            // AI quota belongs to the JetBrains account, not to one IDE.
            bundleIdentifiers: [
                "com.jetbrains.intellij",
                "com.jetbrains.intellij.ce",
                "com.jetbrains.pycharm",
                "com.jetbrains.pycharm.ce",
                "com.jetbrains.WebStorm",
                "com.jetbrains.goland",
                "com.jetbrains.rider",
                "com.jetbrains.CLion",
                "com.jetbrains.PhpStorm",
                "com.jetbrains.rubymine",
                "com.jetbrains.rustrover",
                "com.jetbrains.datagrip",
                "com.google.android.studio",
            ],
            webURL: URL(string: "https://www.jetbrains.com/ai/")
        ),
        Self(
            id: .windsurf,
            name: "Windsurf",
            systemImage: "wind",
            bundleIdentifiers: ["com.exafunction.windsurf"],
            webURL: URL(string: "https://windsurf.com")
        ),
        Self(
            id: .antigravity,
            name: "Antigravity",
            systemImage: "a.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://antigravity.google")
        ),
        Self(
            id: .copilot,
            name: "GitHub Copilot",
            systemImage: "chevron.left.forwardslash.chevron.right",
            bundleIdentifiers: [],
            webURL: URL(string: "https://github.com/settings/copilot/features")
        ),
        Self(
            id: .kiro,
            name: "Kiro",
            systemImage: "k.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://app.kiro.dev/account/usage")
        ),
        Self(
            id: .amp,
            name: "Amp",
            systemImage: "bolt.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://ampcode.com/settings")
        ),
        Self(
            id: .muse,
            name: "Muse Code",
            systemImage: "m.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://www.meta.ai")
        ),
        Self(
            id: .ohMyPi,
            name: "Oh My Pi",
            systemImage: "function",
            bundleIdentifiers: [],
            webURL: URL(string: "https://omp.sh")
        ),
        Self(
            id: .commandCode,
            name: "Command Code",
            systemImage: "command",
            bundleIdentifiers: [],
            webURL: URL(string: "https://commandcode.ai/usage")
        ),
        Self(
            id: .cline,
            name: "Cline",
            systemImage: "c.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://app.cline.bot/dashboard")
        ),
        Self(
            id: .openCodeGo,
            name: "OpenCode Go",
            systemImage: "o.circle",
            bundleIdentifiers: [],
            webURL: URL(string: "https://opencode.ai/auth")
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
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard !id.isEmpty,
              let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed)
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
    var circular = false

    var body: some View {
        Group {
            if let image = BundledToolMark.image(for: tool.id) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
            } else if circular {
                badge(in: Circle())
            } else {
                badge(in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // Match the graphite and porcelain gradients in Design/AppIcon.svg.
    private func badge<Plate: InsettableShape>(in plate: Plate) -> some View {
        let graphite = LinearGradient(stops: [
            .init(color: Color(railHex: 0x303137), location: 0),
            .init(color: Color(railHex: 0x1C1D22), location: 0.49),
            .init(color: Color(railHex: 0x0E0F12), location: 1),
        ], startPoint: UnitPoint(x: 0.117, y: 0.039), endPoint: UnitPoint(x: 0.828, y: 0.996))
        let porcelain = LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: Color(railHex: 0xF5F4EF), location: 0.47),
            .init(color: Color(railHex: 0xD9D9D5), location: 1),
        ], startPoint: UnitPoint(x: 0.406, y: 0.172), endPoint: UnitPoint(x: 0.605, y: 0.820))

        return plate.fill(graphite)
            .overlay(plate.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
            .overlay(porcelain.mask(fallbackSymbol))
    }

    private var fallbackSymbol: some View {
        Image(systemName: tool.systemImage)
            .resizable()
            .scaledToFit()
            .padding(size * 0.16)
            .foregroundColor(.white)
            .frame(width: size, height: size)
    }
}
