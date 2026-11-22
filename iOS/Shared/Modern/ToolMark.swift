import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which mark a tool is drawn with: the vendor's own mark where usAIge has
/// one, otherwise the SF Symbol the Mac chose for it.
enum ToolMarkKind: Equatable, Sendable {
    case chatGPT
    case claude
    case cursor
    case grok
    case gemini
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
        } else {
            let symbol = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self = .symbol(symbol.isEmpty ? Self.fallbackSymbol : symbol)
        }
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
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(
                x: (proxy.size.width - side) / 2,
                y: (proxy.size.height - side) / 2,
                width: side,
                height: side
            )
            ZStack {
                switch kind {
                case .chatGPT: chatGPT
                case .claude: ClaudeSparkMark(rect: rect)
                case .cursor: CursorCubeMark(rect: rect)
                case .grok: GrokDiscMark(rect: rect)
                case .gemini: GeminiSparkMark(rect: rect)
                case .symbol(let name): symbol(name)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// ChatGPT's mark ships as an image in the app's asset catalog; a target
    /// without it, such as the complication, falls back to a symbol.
    @ViewBuilder
    private var chatGPT: some View {
        if Self.hasImage(named: "ChatGPTMark") {
            Image("ChatGPTMark")
                .resizable()
                .interpolation(.high)
                .renderingMode(.template)
                .scaledToFit()
        } else {
            symbol(fallbackSymbol ?? ToolMarkKind.fallbackSymbol)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: Self.hasSymbol(named: name) ? name : ToolMarkKind.fallbackSymbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .padding(2)
    }

    private static func hasImage(named name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(named: name) != nil
        #else
        true
        #endif
    }

    private static func hasSymbol(named name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        true
        #endif
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

// The vendor marks below are the same vector renditions the Mac draws.

/// Claude's starburst: spokes of alternating length with rounded ends.
private struct ClaudeSparkMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let lengths: [Double] = [0.47, 0.30, 0.40, 0.33, 0.46, 0.29, 0.42, 0.35, 0.47, 0.31, 0.39, 0.34]
            let spokes = lengths.count
            for (index, factor) in lengths.enumerated() {
                let angle = Double(index) / Double(spokes) * 2 * .pi - .pi / 2 + (index.isMultiple(of: 3) ? 0.08 : -0.05)
                let length = rect.width * factor
                let inner = rect.width * 0.05
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
            }
        }
        .stroke(style: StrokeStyle(lineWidth: rect.width * 0.11, lineCap: .round))
    }
}

/// Cursor's isometric cube.
private struct CursorCubeMark: View {
    let rect: CGRect

    private var vertices: [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.46
        return (0..<6).map { index in
            let angle = Double(index) * .pi / 3 - .pi / 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    var body: some View {
        let points = vertices
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ZStack {
            Path { path in
                path.move(to: points[0])
                path.addLine(to: points[1])
                path.addLine(to: center)
                path.addLine(to: points[5])
                path.closeSubpath()
            }
            .fill(Color.primary.opacity(0.28))
            Path { path in
                path.move(to: points[5])
                path.addLine(to: center)
                path.addLine(to: points[3])
                path.addLine(to: points[4])
                path.closeSubpath()
            }
            .fill(Color.primary.opacity(0.62))
            Path { path in
                path.addLines(points)
                path.closeSubpath()
                for index in [0, 2, 4] {
                    path.move(to: center)
                    path.addLine(to: points[index])
                }
            }
            .stroke(style: StrokeStyle(lineWidth: rect.width * 0.07, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Grok's mark: a ring open on the right whose lower end sweeps inward.
private struct GrokDiscMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width * 0.36
            path.addArc(center: center, radius: radius, startAngle: .degrees(14), endAngle: .degrees(318), clockwise: false)
            let tailY = center.y + sin(14 * Double.pi / 180) * radius
            path.move(to: CGPoint(x: center.x + cos(14 * Double.pi / 180) * radius, y: tailY))
            path.addLine(to: CGPoint(x: center.x - radius * 0.05, y: tailY))
        }
        .stroke(style: StrokeStyle(lineWidth: rect.width * 0.17, lineCap: .round, lineJoin: .round))
    }
}

/// Gemini's four-point spark with concave sides.
private struct GeminiSparkMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = rect.width * 0.5
            let pinch = rect.width * 0.11
            path.move(to: CGPoint(x: center.x, y: center.y - outer))
            path.addQuadCurve(to: CGPoint(x: center.x + outer, y: center.y), control: CGPoint(x: center.x + pinch, y: center.y - pinch))
            path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + outer), control: CGPoint(x: center.x + pinch, y: center.y + pinch))
            path.addQuadCurve(to: CGPoint(x: center.x - outer, y: center.y), control: CGPoint(x: center.x - pinch, y: center.y + pinch))
            path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - outer), control: CGPoint(x: center.x - pinch, y: center.y - pinch))
            path.closeSubpath()
        }
        .fill()
    }
}
