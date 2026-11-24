import SwiftUI

/// CPU detail shared by the dashboard and the legacy settings sheet.
struct ThisMacPage: View {
    let liveWork: LiveWorkMonitor?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CPU", bundle: AppLanguage.resourceBundle)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
                if let liveWork {
                    CPUReadings(monitor: liveWork.cpu)
                } else {
                    Text("CPU readings are unavailable.", bundle: AppLanguage.resourceBundle).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

private struct CPUReadings: View {
    @ObservedObject var monitor: SystemCPUMonitor
    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        if #available(macOS 14.0, *), interfaceStyle == .modern {
            ModernCard(padding: 20) { readings }
        } else {
            GroupBox { readings.padding(12) }
        }
    }

    private var readings: some View {
        let usage = monitor.usage
        let status = usage?.trendStatus ?? .unknown
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(usage.map { LiveWorkText.percent($0.busy) } ?? "–")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("in use", bundle: AppLanguage.resourceBundle).font(.title3).foregroundColor(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("CPU in use", bundle: AppLanguage.resourceBundle))
                .accessibilityValue(accessiblePercent(usage?.busy))
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    status.localizedTitle
                }
                .font(.callout.weight(.medium))
                .foregroundColor(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("CPU status", bundle: AppLanguage.resourceBundle))
                .accessibilityValue(status.localizedTitle)
                Spacer(minLength: 8)
                Text("\(ProcessInfo.processInfo.activeProcessorCount) logical cores", bundle: AppLanguage.resourceBundle)
                    .font(.callout).foregroundColor(.secondary)
            }
            Text("Last 10 minutes", bundle: AppLanguage.resourceBundle).font(.headline)
            CPUTrendChart(samples: monitor.samples, plotHeight: 180)
            CPUTimeBreakdown(usage: usage, barHeight: ProportionalBar.detailHeight)
        }
    }
}

struct CPUTimeBreakdown: View {
    let usage: SystemCPUUsage?
    var barHeight = ProportionalBar.thinHeight
    var compact = false

    private struct TimeShare: Identifiable {
        let title: String
        let color: Color
        let fraction: Double?
        var id: String { title }
    }

    var body: some View {
        let shares = [
            TimeShare(title: "User", color: Color(NSColor.systemBlue), fraction: usage?.user),
            TimeShare(title: "System", color: Color(NSColor.systemPink), fraction: usage?.system),
            TimeShare(title: "Idle", color: Color(NSColor.systemGray), fraction: usage?.idle)
        ]
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ProportionalBar(segments: shares.map {
                .init(id: $0.id, fraction: $0.fraction ?? 0, color: $0.color)
            }, height: barHeight)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 80 : 110), alignment: .leading)], alignment: .leading) {
                ForEach(shares) { share in
                    HStack(spacing: 6) {
                        Circle().fill(share.color).frame(width: 8, height: 8)
                        Text(LocalizedStringKey(share.title), bundle: AppLanguage.resourceBundle)
                            .foregroundColor(.secondary)
                        Text(share.fraction.map(LiveWorkText.percent) ?? "–")
                            .font(.caption.monospacedDigit())
                    }
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(LocalizedStringKey(share.title), bundle: AppLanguage.resourceBundle))
                    .accessibilityValue(accessiblePercent(share.fraction))
                }
            }
        }
    }
}

struct CPUHoverCard: View {
    @ObservedObject var monitor: SystemCPUMonitor
    let open: (() -> Void)?

    var body: some View {
        let usage = monitor.usage
        let status = usage?.trendStatus ?? .unknown
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU", bundle: AppLanguage.resourceBundle).font(.headline)
                Spacer()
                Text(usage.map { LiveWorkText.percent($0.busy) } ?? "–")
                    .font(.headline.monospacedDigit())
                Text("in use", bundle: AppLanguage.resourceBundle)
            }
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                status.localizedTitle
                Spacer()
                Text("\(ProcessInfo.processInfo.activeProcessorCount) logical cores", bundle: AppLanguage.resourceBundle)
            }
            .foregroundColor(.secondary)
            Text("Last 10 minutes", bundle: AppLanguage.resourceBundle).fontWeight(.semibold)
            CPUTrendChart(samples: monitor.samples, plotHeight: 68)
            CPUTimeBreakdown(usage: usage, compact: true)
            if let open {
                Button(action: open) { Text("Open CPU", bundle: AppLanguage.resourceBundle) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }
}

private func accessiblePercent(_ value: Double?) -> Text {
    value.map { Text(verbatim: LiveWorkText.percent($0)) } ?? Text("Unavailable", bundle: AppLanguage.resourceBundle)
}
