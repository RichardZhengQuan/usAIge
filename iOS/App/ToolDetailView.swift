import Foundation
import SwiftUI

struct ToolDetailView: View {
    let tool: ToolUsageSummary

    var body: some View {
        let credit = tool.limits.first { ($0.availableResetCount ?? 0) > 0 }
        let session = tool.activeSession
        let hasToolInfo = credit != nil || session != nil
        let lastLimitID = tool.limits.last?.id
        let updatedAt = tool.limits.lazy.map(\.updatedAt).max()

        List {
            ForEach(tool.limits) { limit in
                Section {
                    ModernQuotaBar(window: limit.primaryWindow)
                    if let secondary = limit.secondaryWindow {
                        ModernQuotaBar(window: secondary)
                    }
                } header: {
                    limitTitle(limit)
                        .textCase(nil)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    if !hasToolInfo, limit.id == lastLimitID {
                        updatedFooter(updatedAt)
                    }
                }
            }

            if hasToolInfo {
                Section {
                    if let credit, let count = credit.availableResetCount {
                        fullResetsRow(count: count, expiresAt: credit.resetCreditExpiresAt)
                    }
                    if let session {
                        sessionRow(session)
                    }
                } footer: {
                    updatedFooter(updatedAt)
                }
            }
        }
        .listStyle(.insetGrouped)
        .readableListWidth()
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
    private func updatedFooter(_ updatedAt: Date?) -> some View {
        if let updatedAt {
            Text("Updated \(.currentDate, format: .reference(to: updatedAt, maxFieldCount: 1))")
        }
    }

    private func fullResetsRow(count: Int, expiresAt: Date?) -> some View {
        let label = Text("Full resets")
        let value = if let expiresAt {
            Text("\(count) available · expires \(expiresAt, format: .dateTime.month(.abbreviated).day())")
        } else {
            Text("\(count) available")
        }

        return ViewThatFits(in: .horizontal) {
            LabeledContent {
                value.fixedSize(horizontal: true, vertical: false)
            } label: {
                label.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 2) {
                label
                value
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ session: CodexSessionStatus) -> some View {
        let phase = HStack(spacing: 8) {
            UsageSessionDot(phase: session.phase)
            Text(session.phase.label)
        }
        let relativeTime = Text(.currentDate, format: .reference(to: session.updatedAt, maxFieldCount: 1))
            .foregroundStyle(.secondary)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                phase
                relativeTime
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 2) {
                phase
                relativeTime
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
