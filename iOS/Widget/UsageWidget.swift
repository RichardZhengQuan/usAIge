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
            // WidgetKit's configuration sheet does not consistently show an
            // entity subtitle. Keep the actual limit in the primary label so
            // multiple limits from the same tool are always distinguishable.
            title: "\(limitName) — \(toolName)",
            subtitle: "\(toolName)"
        )
    }
}

struct WidgetQuotaEntityQuery: EntityQuery {
    // AppIntent entity queries run in a short-lived system process. Keep this
    // read bounded and resolve a transient cache error as an empty result so
    // WidgetKit's configuration picker always finishes loading.
    private let cacheURL = SharedQuotaCache().storageURL

    func entities(for identifiers: [WidgetQuotaEntity.ID]) async throws -> [WidgetQuotaEntity] {
        let identifiers = Set(identifiers)
        return availableEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetQuotaEntity] {
        availableEntities()
    }

    private func availableEntities() -> [WidgetQuotaEntity] {
        let cacheState = (try? JSONFileStorage.load(QuotaCacheState.self, from: cacheURL)) ?? .empty
        return cacheState.snapshots
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

    @Parameter(title: "First limit")
    var firstLimit: WidgetQuotaEntity?

    @Parameter(title: "Second limit")
    var secondLimit: WidgetQuotaEntity?

    @Parameter(title: "Third limit")
    var thirdLimit: WidgetQuotaEntity?

    @Parameter(title: "Fourth limit")
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
