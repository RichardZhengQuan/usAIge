import Foundation
import SwiftUI
import UIKit

/// The vendor's own mark where available, or the SF Symbol the Mac chose.
enum ToolMarkKind: Equatable, Sendable {
    case chatGPT
    case claude
    case cursor
    case grok
    case gemini
    case jetBrains
    case windsurf
    case githubCopilot
    case cline
    case openCode
    case symbol(String)

    static let fallbackSymbol = "sparkles"

    init(toolName: String, symbolName: String?) {
        let name = toolName.lowercased()
        if name.contains("chatgpt") || name.contains("codex") || name.contains("openai") {
            self = .chatGPT
        } else if name.contains("claude") {
            self = .claude
        } else if name.contains("cursor") {
            self = .cursor
        } else if name.contains("grok") {
            self = .grok
        } else if name.contains("gemini") {
            self = .gemini
        } else if name.contains("jetbrains") {
            self = .jetBrains
        } else if name.contains("windsurf") {
            self = .windsurf
        } else if name.contains("copilot") {
            self = .githubCopilot
        } else if name.range(of: #"\bcline\b"#, options: .regularExpression) != nil {
            self = .cline
        } else if name.contains("opencode") {
            self = .openCode
        } else {
            self = .symbol(Self.validSymbolName(symbolName))
        }
    }

    var assetName: String? {
        switch self {
        case .chatGPT: "ToolMarkChatGPT"
        case .claude: "ToolMarkClaude"
        case .cursor: "ToolMarkCursor"
        case .grok: "ToolMarkGrok"
        case .gemini: "ToolMarkGemini"
        case .jetBrains: "ToolMarkJetBrains"
        case .windsurf: "ToolMarkWindsurf"
        case .githubCopilot: "ToolMarkGitHubCopilot"
        case .cline: "ToolMarkCline"
        case .openCode: "ToolMarkOpenCode"
        case .symbol: nil
        }
    }

    // Balance the artwork's built-in margins and visual weight within the same frame.
    fileprivate var assetScale: CGFloat {
        switch self {
        case .chatGPT, .symbol: 1
        case .claude, .githubCopilot: 0.94
        case .cursor: 0.86
        case .grok, .windsurf: 0.96
        case .gemini: 0.92
        case .jetBrains: 0.82
        case .cline, .openCode: 0.90
        }
    }

    fileprivate static func validSymbolName(_ symbolName: String?) -> String {
        guard let name = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, UIImage(systemName: name) != nil else {
            return fallbackSymbol
        }
        return name
    }
}

/// A tool's mark, drawn in the current foreground style.
struct ToolMark: View {
    let kind: ToolMarkKind
    /// The symbol to use when the vendor mark can't be drawn here.
    var fallbackSymbol: String?

    init(kind: ToolMarkKind, fallbackSymbol: String? = nil) {
        self.kind = kind
        self.fallbackSymbol = fallbackSymbol
    }

    init(toolName: String, symbolName: String?) {
        self.init(kind: ToolMarkKind(toolName: toolName, symbolName: symbolName), fallbackSymbol: symbolName)
    }

    var body: some View {
        Group {
            if let assetName = kind.assetName, UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(kind.assetScale)
            } else if case .symbol(let name) = kind {
                symbol(name)
            } else {
                symbol(fallbackSymbol)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String?) -> some View {
        Image(systemName: ToolMarkKind.validSymbolName(name))
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .padding(2)
    }
}

/// A tool's mark on a quiet rounded square, as in the Mac's Modern rows.
struct ToolMarkTile: View {
    let kind: ToolMarkKind
    var fallbackSymbol: String?
    var size: CGFloat = 30

    var body: some View {
        ToolMark(kind: kind, fallbackSymbol: fallbackSymbol)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}
