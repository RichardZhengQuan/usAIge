import Foundation
import SwiftUI

struct QuotaRow: View {
    let tool: ToolUsageSummary

    var body: some View {
        let limit = tool.tightest
        let phase = tool.activeSession?.phase

        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 8) {
                header(phase: phase)
                ModernQuotaBar(window: limit.primaryWindow)
                if let secondary = limit.secondaryWindow {
                    ModernQuotaBar(window: secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle(phase: phase))
            .accessibilityValue(Text(accessibilityWindows(now: context.date)))
        }
    }

    private func header(phase: CodexSessionPhase?) -> some View {
        let title = HStack(spacing: 6) {
            Text(tool.name).font(.headline)
            if let phase {
                UsageSessionDot(phase: phase)
            }
        }

        return HStack(spacing: 8) {
            ToolMarkTile(
                kind: ToolMarkKind(toolName: tool.name, symbolName: tool.symbolName),
                fallbackSymbol: tool.symbolName
            )
            if tool.otherLimitCount > 0 {
                let caption = limitCaption.font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        caption
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        caption
                    }
                }
            } else {
                title
            }
        }
        .foregroundStyle(.primary)
    }

    private var limitCaption: Text {
        Text("\(tool.tightest.displayName) · +\(tool.otherLimitCount) more")
    }

    private func accessibilityTitle(phase: CodexSessionPhase?) -> Text {
        let name = Text(tool.name)
        let title = tool.otherLimitCount > 0 ? Text("\(name), \(limitCaption)") : name
        if let phase {
            return Text("\(title), \(phase.label)")
        }
        return title
    }

    private func accessibilityWindows(now: Date) -> String {
        let limit = tool.tightest
        let windows = [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }
        return windows.map { window in
            let percent = Int(window.remainingPercent.rounded())
            let reset = ResetCountdown.accessibilityLabel(until: window.resetAt, now: now)
            return String(localized: "\(window.typeTag) window, \(percent) percent left, \(reset)")
        }.joined(separator: ". ")
    }
}

struct UsageSessionDot: View {
    let phase: CodexSessionPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch phase {
        case .idle: .clear
        case .thinking: .blue
        case .complete: .green
        case .needsInput: .orange
        case .error: .red
        }
    }
}

extension ToolUsageSummary {
    var activeSession: CodexSessionStatus? {
        let session = limits.lazy.compactMap(\.sessionStatus).max { $0.updatedAt < $1.updatedAt }
        guard let session, session.phase.showsLight else { return nil }
        return session
    }
}

extension ModernQuotaBar {
    init(window: QuotaWindowSnapshot) {
        self.init(tag: window.typeTag, remainingPercent: window.remainingPercent, resetAt: window.resetAt)
    }
}
