import SwiftUI

/// CPU detail for the This Mac sidebar section and the legacy settings sheet.
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
            HStack(spacing: 12) {
                Text("History", bundle: AppLanguage.resourceBundle).font(.headline)
                Spacer(minLength: 4)
                SystemTrendRangePicker()
            }
            CPUTrendChart(samples: monitor.samples, plotHeight: 145)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                timeShare("User", usage?.user)
                timeShare("System", usage?.system)
                timeShare("Idle", usage?.idle)
            }
        }
    }

    private func timeShare(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle).font(.callout).foregroundColor(.secondary)
            Text(value.map(LiveWorkText.percent) ?? "–")
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title), bundle: AppLanguage.resourceBundle))
        .accessibilityValue(accessiblePercent(value))
    }

    private func accessiblePercent(_ value: Double?) -> Text {
        value.map { Text(verbatim: LiveWorkText.percent($0)) } ?? Text("Unavailable", bundle: AppLanguage.resourceBundle)
    }
}
