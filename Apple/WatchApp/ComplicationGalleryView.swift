#if DEBUG
import Foundation
import SwiftUI
import WidgetKit

struct ComplicationGalleryView: View {
    private let entry = UsageTimelineEntry(date: .now, envelope: UsageDemoData.envelope())
    private let circularSize = CGSize(width: 52, height: 52)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Approximate 46 mm watch-face slots based on Apple's Complications HIG.
                    sample("Accessory Circular", family: .accessoryCircular, size: circularSize, entry: entry)
                    sample("Accessory Rectangular", family: .accessoryRectangular, size: CGSize(width: 188, height: 59), entry: entry)
                    sample("Accessory Inline", family: .accessoryInline, size: CGSize(width: 188, height: 20), entry: entry)
                    sample("Accessory Corner", family: .accessoryCorner, size: CGSize(width: 40, height: 40), entry: entry)

                    if let envelope = entry.envelope {
                        ForEach(envelope.tools) { tool in
                            let toolEntry = UsageTimelineEntry(
                                date: entry.date,
                                envelope: WatchUsageSnapshotEnvelope(generatedAt: envelope.generatedAt, tools: [tool])
                            )
                            sample(tool.displayName, family: .accessoryCircular, size: circularSize, entry: toolEntry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .background(.black)
            .navigationTitle("Complications")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sample(_ title: String, family: WidgetFamily, size: CGSize, entry: UsageTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            UsageComplicationView(entry: entry, family: family)
                .font(.system(size: 14, design: .rounded))
                .frame(minWidth: 0, maxWidth: size.width, minHeight: size.height, maxHeight: size.height)
                .background(.black)
                .overlay {
                    Rectangle()
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                        .accessibilityHidden(true)
                }
        }
    }
}
#endif
