import Foundation
import SwiftUI

struct DashboardView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
        let sections = macSections
        let hasReadings = sections.contains { !$0.snapshots.isEmpty }

        Group {
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("Connect your Mac", systemImage: "macbook.and.iphone")
                } description: {
                    Text("Open iPhone Sync in usAIge Settings on your Mac, then enter its pairing code in the Connection tab.")
                }
            } else if !hasReadings, model.isRefreshing {
                ProgressView("Getting limits from your Macs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasReadings {
                ContentUnavailableView {
                    Label("Limits unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? "Keep usAIge running on a connected Mac, then try again.")
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        .usaigeProminentButtonStyle()
                }
            } else {
                quotaList(sections)
            }
        }
        .background(ModernPalette.page)
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                    .disabled(isShowingDemo || !model.isConnected || model.isRefreshing)
            }
        }
    }

    private func quotaList(_ sections: [MacUsageSection]) -> some View {
        List {
            if !isShowingDemo, model.isCacheStale || model.errorMessage != nil {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Showing saved limits")
                                .font(.headline)
                            Text(model.errorMessage ?? model.statusDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(sections) { section in
                let tools = ToolUsageSummary.group(section.snapshots)
                Section {
                    if tools.isEmpty {
                        Label("Waiting for this Mac to upload limits", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tools) { tool in
                        NavigationLink {
                            ToolDetailView(tool: tool)
                        } label: {
                            QuotaRow(tool: tool)
                        }
                    }
                } header: {
                    Text(section.name)
                        .textCase(nil)
                } footer: {
                    if let updated = section.updatedAt {
                        Text("Updated \(.currentDate, format: .reference(to: updated, maxFieldCount: 1))")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            if !isShowingDemo { await model.refreshAll() }
        }
        .overlay(alignment: .top) {
            if !isShowingDemo, model.isRefreshing {
                ProgressView()
                    .padding(10)
                    .usaigeRefreshSurface()
                    .padding(.top, 8)
            }
        }
    }

    private var macSections: [MacUsageSection] {
        #if DEBUG
        if isShowingDemo { return Self.demoSections }
        #endif
        return model.connectionStates.map { state in
            MacUsageSection(
                id: state.connection.channelID,
                name: state.connection.macName,
                snapshots: state.snapshots,
                updatedAt: state.serverReceivedAt
            )
        }
    }

    private var isShowingDemo: Bool {
        #if DEBUG
        UsageDemoData.isEnabled
        #else
        false
        #endif
    }

    #if DEBUG
    private static var demoSections: [MacUsageSection] {
        UsageDemoData.macSections().map {
            MacUsageSection(id: $0.id, name: $0.name, snapshots: $0.snapshots, updatedAt: $0.updatedAt)
        }
    }
    #endif
}

private struct MacUsageSection: Identifiable {
    let id: UUID
    let name: String
    let snapshots: [QuotaSnapshot]
    let updatedAt: Date?
}

extension View {
    @ViewBuilder
    func usaigeProminentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func usaigeGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func usaigeRefreshSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .circle)
        } else {
            background(.regularMaterial, in: Circle())
        }
    }
}
