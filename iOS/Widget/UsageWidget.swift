import AppIntents
import SwiftUI
import WidgetKit

struct WidgetQuotaEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AI Limit"
    static let defaultQuery = WidgetQuotaEntityQuery()

    let id: String
    let toolName: String
    let limitName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(toolName)",
            subtitle: "\(limitName)"
        )
    }
}

struct WidgetQuotaEntityQuery: EntityQuery {
    private let cache = SharedQuotaCache()

    func entities(for identifiers: [WidgetQuotaEntity.ID]) async throws -> [WidgetQuotaEntity] {
        let identifiers = Set(identifiers)
        return try await availableEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetQuotaEntity] {
        try await availableEntities()
    }

    private func availableEntities() async throws -> [WidgetQuotaEntity] {
        try await cache.load().snapshots
            .sorted(by: QuotaTimelineProvider.areInDisplayOrder)
            .map {
                WidgetQuotaEntity(
                    id: $0.id,
                    toolName: $0.toolName,
                    limitName: $0.displayName
                )
            }
    }
}

struct UsageWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose AI Limits"
    static let description = IntentDescription(
        "Choose which AI limits appear in this widget and their order."
    )

    @Parameter(title: "Limit")
    var firstLimit: WidgetQuotaEntity?

    @Parameter(title: "Second")
    var secondLimit: WidgetQuotaEntity?

    @Parameter(title: "Third")
    var thirdLimit: WidgetQuotaEntity?

    @Parameter(title: "Fourth")
    var fourthLimit: WidgetQuotaEntity?

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) {
                Summary("Show \(\.$firstLimit)")
            }
            DefaultCase {
                Summary("Show \(\.$firstLimit), \(\.$secondLimit), \(\.$thirdLimit), \(\.$fourthLimit)")
            }
        }
    }

    var selectedLimitIDs: [String] {
        var seen = Set<String>()
        return [firstLimit, secondLimit, thirdLimit, fourthLimit]
            .compactMap { $0?.id }
            .filter { seen.insert($0).inserted }
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
