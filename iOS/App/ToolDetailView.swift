import Foundation
import SwiftUI

struct ToolDetailView: View {
    let tool: ToolUsageSummary

    var body: some View {
        List {
            ForEach(tool.limits) { limit in
                let isLastLimit = limit.id == tool.limits.last?.id
                Section {
                    ModernQuotaBar(window: limit.primaryWindow)
                    if let secondary = limit.secondaryWindow {
                        ModernQuotaBar(window: secondary)
                    }
                    if isLastLimit {
                        toolInfoRows
                    }
                } header: {
                    limitTitle(limit)
                        .textCase(nil)
                } footer: {
                    if isLastLimit, let updated = tool.limits.lazy.map(\.updatedAt).max() {
                        Text("Updated \(.currentDate, format: .reference(to: updated, maxFieldCount: 1))")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(tool.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func limitTitle(_ limit: QuotaSnapshot) -> Text {
        let name = Text(limit.displayName)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        if let plan = limit.planType, !plan.isEmpty {
            return Text("\(name) \(Text(plan).foregroundStyle(.secondary))")
        }
        return name
    }

    @ViewBuilder
    private var toolInfoRows: some View {
        if let credit = tool.limits.first(where: { ($0.availableResetCount ?? 0) > 0 }),
           let count = credit.availableResetCount {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(count) available")
                    if let expiry = credit.resetCreditExpiresAt {
                        Text("expires \(expiry, format: .dateTime.month(.abbreviated).day())")
                    }
                }
                .multilineTextAlignment(.trailing)
            } label: {
                Text("Full resets")
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }

        if let session = tool.activeSession {
            HStack(spacing: 8) {
                UsageSessionDot(phase: session.phase)
                Text(session.phase.label)
                Text(.currentDate, format: .reference(to: session.updatedAt, maxFieldCount: 1))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
