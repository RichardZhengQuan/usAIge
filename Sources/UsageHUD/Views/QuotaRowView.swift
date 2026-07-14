import SwiftUI

enum QuotaSeverity: Equatable, Sendable {
    case normal
    case warning
    case critical

    init(remainingPercent: Double) {
        if remainingPercent <= 10 {
            self = .critical
        } else if remainingPercent <= 20 {
            self = .warning
        } else {
            self = .normal
        }
    }

    var color: Color {
        color(normal: .accentColor)
    }

    func color(normal: Color) -> Color {
        switch self {
        case .normal: normal
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct QuotaRowView: View {
    let snapshot: QuotaSnapshot
    let openTool: (AIToolDescriptor) -> Void
    @State private var isHovered = false

    private var tool: AIToolDescriptor {
        .descriptor(for: snapshot.toolID)
    }

    private var primarySeverity: QuotaSeverity {
        QuotaSeverity(remainingPercent: snapshot.remainingPercent)
    }

    private var primaryColor: Color {
        primarySeverity.color(normal: .cyan)
    }

    private var secondaryColor: Color {
        guard let secondaryWindow = snapshot.secondaryWindow else { return .purple }
        return QuotaSeverity(remainingPercent: secondaryWindow.remainingPercent).color(normal: .purple)
    }

    var body: some View {
        VStack(spacing: 4) {
            usageRing

            HStack(spacing: 4) {
                typeTag(snapshot.typeTag, color: primaryColor)
                if let secondaryWindow = snapshot.secondaryWindow {
                    typeTag(secondaryWindow.typeTag, color: secondaryColor)
                }
            }
        }
        .frame(width: 76, height: 76)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            detailPopover
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var usageRing: some View {
        ZStack {
            if let secondaryWindow = snapshot.secondaryWindow {
                Circle()
                    .stroke(.secondary.opacity(0.14), lineWidth: 3)
                    .frame(width: 58, height: 58)
                Circle()
                    .trim(from: 0, to: secondaryWindow.remainingPercent / 100)
                    .stroke(secondaryColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 58, height: 58)
            }

            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 4)
                .frame(width: 46, height: 46)
            Circle()
                .trim(from: 0, to: snapshot.remainingPercent / 100)
                .stroke(primaryColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 46, height: 46)
            Button { openTool(tool) } label: {
                AIToolIcon(tool: tool, size: 23)
            }
            .buttonStyle(.plain)
            .help("Open \(tool.name)")
            .accessibilityLabel("Open \(tool.name)")
        }
        .frame(width: 60, height: 60)
    }

    private func typeTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AIToolIcon(tool: tool, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name).font(.headline)
                    Text(snapshot.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            windowDetail(
                title: snapshot.typeTag,
                window: snapshot.primaryWindow,
                color: primaryColor
            )

            if let secondaryWindow = snapshot.secondaryWindow {
                Divider()
                windowDetail(
                    title: secondaryWindow.typeTag,
                    window: secondaryWindow,
                    color: secondaryColor
                )
            }
            if let planType = snapshot.planType, !planType.isEmpty {
                LabeledContent("Plan") { Text(planType.capitalized) }
            }
        }
        .font(.caption)
        .padding(14)
        .frame(width: 260)
    }

    private func windowDetail(
        title: String,
        window: QuotaWindowSnapshot,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.semibold).foregroundStyle(color)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% remaining")
                    .monospacedDigit()
            }
            QuotaProgressBar(
                remainingPercent: window.remainingPercent,
                color: color
            )
            LabeledContent("Resets") {
                Text(ResetDateText.format(window.resetAt))
            }
        }
    }

    private var accessibilitySummary: String {
        var text = "\(tool.name), \(snapshot.displayName), \(snapshot.typeTag) \(Int(snapshot.remainingPercent.rounded())) percent remaining"
        if let secondaryWindow = snapshot.secondaryWindow {
            text += ", \(secondaryWindow.typeTag) \(Int(secondaryWindow.remainingPercent.rounded())) percent remaining"
        }
        return text
    }

}

private struct QuotaProgressBar: View {
    let remainingPercent: Double
    let color: Color

    private var fraction: Double {
        min(max(remainingPercent / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Quota remaining")
        .accessibilityValue("\(Int(remainingPercent.rounded())) percent")
    }
}

enum ResetDateText {
    static func format(
        _ date: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let date else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
