import SwiftUI

struct ToolsView: View {
    @Environment(RelayAppModel.self) private var model
    @FocusState private var codeFocused: Bool

    var body: some View {
        @Bindable var model = model
        Form {
            if !model.connections.isEmpty {
                Section("Connected Macs") {
                    ForEach(model.connections, id: \.channelID) { connection in
                        NavigationLink {
                            MacConnectionDetailView(connectionID: connection.channelID)
                        } label: {
                            MacConnectionRow(connectionID: connection.channelID)
                        }
                    }
                }
            }

            Section {
                TextField("8-character code", text: $model.pairingCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
                    .onChange(of: model.pairingCode) { _, value in
                        model.pairingCode = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                    }
                Button(model.connections.isEmpty ? "Connect" : "Add Mac", systemImage: "link.badge.plus") {
                    Task { await model.pair() }
                }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .disabled(model.pairingCode.count != 8 || model.isRefreshing)
                if let error = model.pairingErrorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(model.connections.isEmpty ? "Pair with Mac" : "Add Another Mac")
            } footer: {
                Text("On the Mac, open usAIge Settings → iPhone Sync → Create Connection. Each Mac uses its own 8-character code.")
            }

            Section {
                Label("Only normalized limit percentages and reset times are synced.", systemImage: "lock.shield")
            } footer: {
                Text("Provider credentials never reach the relay or this iPhone. Each Mac can be disconnected independently.")
            }
        }
        .navigationTitle("Connection")
        .task { if !model.isConnected { codeFocused = true } }
    }
}

private struct MacConnectionRow: View {
    @Environment(RelayAppModel.self) private var model
    let connectionID: UUID

    var body: some View {
        if let state = model.state(for: connectionID) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.connection.macName)
                    HStack(spacing: 6) {
                        Text("\(state.snapshots.count) limits")
                        if let date = state.serverReceivedAt {
                            Text("· Updated \(date, style: .relative)")
                        } else {
                            Text("· Waiting for data")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: model.errorMessage(for: connectionID) == nil
                    ? "laptopcomputer"
                    : "laptopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(
                        model.errorMessage(for: connectionID) == nil
                            ? Color.primary
                            : Color.orange
                    )
            }
        }
    }
}

private struct MacConnectionDetailView: View {
    @Environment(RelayAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connectionID: UUID

    var body: some View {
        Form {
            if let state = model.state(for: connectionID) {
                Section("Connection") {
                    LabeledContent("Mac", value: state.connection.macName)
                    LabeledContent("Limits", value: "\(state.snapshots.count)")
                    LabeledContent("Last server update") {
                        if let date = state.serverReceivedAt {
                            Text(date, style: .relative)
                        } else {
                            Text("Not yet").foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.errorMessage(for: connectionID) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Button("Refresh Now", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(connectionID: connectionID) }
                    }
                    .disabled(model.isRefreshing)
                }

                Section {
                    Button("Disconnect This Mac", role: .destructive) {
                        Task {
                            await model.disconnect(connectionID: connectionID)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Other connected Macs and their saved limits stay on this iPhone.")
                }
            } else {
                ContentUnavailableView("Mac Disconnected", systemImage: "laptopcomputer.slash")
            }
        }
        .navigationTitle(model.state(for: connectionID)?.connection.macName ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}
