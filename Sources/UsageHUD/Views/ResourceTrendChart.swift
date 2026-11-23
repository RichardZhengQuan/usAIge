import SwiftUI

@available(macOS 14.0, *)
struct ResourceTrendChart: View {
    @ObservedObject var history: ResourceTrendHistory
    let resource: PaperweightID
    var compact = false
    @AppStorage(SystemTrendRange.defaultsKey) private var range = SystemTrendRange.standard

    var body: some View {
        let end = max(Date(), history.samples.last?.date ?? .distantPast)
        let domain = end.addingTimeInterval(-range.duration)...end
        let points = history.samples.filter { domain.contains($0.date) }
        let values = points.compactMap(\.value)
        let status = TrendPoint.currentStatus(in: points, domain: domain)
        let minimum = values.min() ?? 0, maximum = values.max() ?? 0
        let magnitude = max(maximum - minimum, maximum * 0.008, 1_000_000)
        let midpoint = (maximum + minimum) / 2
        let scale = max(0, midpoint - 0.6 * magnitude)...(midpoint + 0.6 * magnitude)
        let name: LocalizedStringKey = resource == .memory ? "Memory in use" : "Free disk space"
        let plotHeight: CGFloat = compact ? 68 : 128
        Group {
            if compact {
                TrendLinePlot(points: points, domain: domain, valueRange: scale, compact: true)
                    .frame(height: plotHeight)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    TrendHistoryPlot(points: points, domain: domain, valueRange: scale, plotHeight: plotHeight) {
                        if values.isEmpty {
                            Text("Waiting for a reading…", bundle: AppLanguage.resourceBundle)
                        }
                    }
                    if !values.isEmpty {
                        VStack(alignment: .trailing) {
                            Text(formattedBytes(scale.upperBound))
                            Spacer(minLength: 2)
                            Text(formattedBytes(scale.lowerBound))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: plotHeight)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name, bundle: AppLanguage.resourceBundle))
        .accessibilityValue(values.isEmpty ? Text("Waiting for a reading…", bundle: AppLanguage.resourceBundle)
                            : Text("\(Text(LocalizedStringKey(status.title), bundle: AppLanguage.resourceBundle)) · \(formattedBytes(minimum)) – \(formattedBytes(maximum))"))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func formattedBytes(_ value: Double) -> String {
        resource.formatBytes(value >= Double(Int64.max) ? .max : Int64(max(0, value)))
    }
}
