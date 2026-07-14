import SwiftUI
import WidgetKit

@main
struct UsageWidget: Widget {
    static let kind = "com.richardq.usaige.limits"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Limits")
        .description("See cached usage limits for your connected AI tools.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
