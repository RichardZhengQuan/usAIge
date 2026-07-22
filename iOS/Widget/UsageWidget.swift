import AppIntents
import SwiftUI
import WidgetKit

struct WidgetLimitOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        var items = [
            IntentItem(
                WidgetLimitSelection.automaticID,
                title: "Automatic",
                subtitle: "Show the limits needing attention first"
            )
        ]

        if let state = try? await SharedQuotaCache().load() {
            var seenIDs = Set<String>()
            items += state.snapshots
                .sorted(by: QuotaTimelineProvider.areInDisplayOrder)
                .filter { seenIDs.insert($0.id).inserted }
                .map { snapshot in
                    IntentItem(
                        snapshot.id,
                        title: LocalizedStringResource(
                            stringLiteral: "\(snapshot.displayName) — \(snapshot.toolName)"
                        )
                    )
                }
        }

        // App Intents dismisses an options sheet that resolves to no values on
        // some physical devices. Automatic keeps the result valid even while
        // the App Group cache is unavailable or being replaced.
        return IntentItemCollection(
            sections: [IntentItemSection(items: items)]
        )
    }

    func defaultResult() async -> String? {
        WidgetLimitSelection.automaticID
    }
}

/// V2 intentionally has a new App Intent identity. Earlier releases shipped
/// incompatible entity-based and parameterless schemas under the original
/// intent name, which can remain cached on a physical iPhone.
struct UsageWidgetConfigurationIntentV2: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose AI Limits"
    static let description = IntentDescription(
        "Choose which AI limits appear in this widget and their order."
    )

    @Parameter(
        title: "First limit",
        optionsProvider: WidgetLimitOptionsProvider()
    )
    var firstLimitID: String?

    @Parameter(
        title: "Second limit",
        optionsProvider: WidgetLimitOptionsProvider()
    )
    var secondLimitID: String?

    @Parameter(
        title: "Third limit",
        optionsProvider: WidgetLimitOptionsProvider()
    )
    var thirdLimitID: String?

    @Parameter(
        title: "Fourth limit",
        optionsProvider: WidgetLimitOptionsProvider()
    )
    var fourthLimitID: String?

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) {
                Summary("Show \(\.$firstLimitID)")
            }
            DefaultCase {
                Summary(
                    "Show \(\.$firstLimitID), \(\.$secondLimitID), \(\.$thirdLimitID), \(\.$fourthLimitID)"
                )
            }
        }
    }

    var selectedLimitIDs: [String] {
        WidgetLimitSelection.explicitIDs(
            from: [firstLimitID, secondLimitID, thirdLimitID, fourthLimitID]
        )
    }
}

@main
struct UsageWidget: Widget {
    static let kind = "com.richardq.usaige.limits"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: UsageWidgetConfigurationIntentV2.self,
            provider: QuotaTimelineProvider()
        ) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Limits")
        .description("See cached usage limits for your connected AI tools.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
