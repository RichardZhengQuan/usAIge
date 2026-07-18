import SwiftUI

struct DashboardView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView {
                    Label("Connect your Mac", systemImage: "macbook.and.iphone")
                } description: {
                    Text("Open iPhone Sync in usAIge Settings on your Mac, then enter its pairing code in the Connection tab.")
                }
            } else if model.snapshots.isEmpty, model.isRefreshing {
                ProgressView("Getting limits from your Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.snapshots.isEmpty {
                ContentUnavailableView {
                    Label("Limits unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? "Keep usAIge running on your Mac, then try again.")
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        .buttonStyle(.glassProminent)
                }
            } else {
                quotaList
            }
        }
        .navigationTitle("AI Usage")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                .disabled(!model.isConnected || model.isRefreshing)
        }
    }

    private var quotaList: some View {
        List {
            if model.isCacheStale || model.errorMessage != nil {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Showing saved limits").font(.headline)
                            Text(model.errorMessage ?? model.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                }
            }
            ForEach(groupedTools, id: \.id) { tool in
                Section {
                    ForEach(tool.values) { QuotaRow(snapshot: $0) }
                } header: {
                    Label(tool.name, systemImage: "sparkles")
                } footer: {
                    if let updated = tool.values.map(\.updatedAt).min() { Text("Updated \(updated, style: .relative)") }
                }
            }
        }
        .refreshable { await model.refreshAll() }
        .overlay(alignment: .top) {
            if model.isRefreshing { ProgressView().padding(10).glassEffect(.regular, in: .circle).padding(.top, 8) }
        }
    }

    private var groupedTools: [(id: UUID, name: String, values: [QuotaSnapshot])] {
        var seen: [UUID] = []
        for snapshot in model.snapshots where !seen.contains(snapshot.toolID) { seen.append(snapshot.toolID) }
        return seen.map { id in
            let values = model.snapshots.filter { $0.toolID == id }
            return (id, values.first?.toolName ?? "AI Tool", values)
        }
    }
}
