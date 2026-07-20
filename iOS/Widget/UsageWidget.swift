import AppIntents
import SwiftUI
import WidgetKit

struct UsageWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI Limits"
    static let description = IntentDescription(
        "Shows the limits that need your attention first."
    )

    var selectedLimitIDs: [String] {
        []
    }
}

@main
struct UsageWidget: Widget {
    static let kind = "com.richardq.usaige.limits"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: UsageWidgetConfigurationIntent.self,
            provider: QuotaTimelineProvider()
        ) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Limits")
        .description("See cached usage limits for your connected AI tools.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
