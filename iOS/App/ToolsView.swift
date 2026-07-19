import SwiftUI

struct ToolsView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
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
            } else {
                MacPairingSection(isAddingAnotherMac: false)
            }

            Section {
                Label("Only normalized limit percentages and reset times are synced.", systemImage: "lock.shield")
            } footer: {
                Text("Provider credentials never reach the relay or this iPhone. Each Mac can be disconnected independently.")
            }
        }
        .navigationTitle("Connection")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if !model.connections.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AddMacView()
                    } label: {
                        Label("Add Mac", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct AddMacView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            MacPairingSection(isAddingAnotherMac: true) {
                dismiss()
            }
        }
        .navigationTitle("Add Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MacPairingSection: View {
    @Environment(RelayAppModel.self) private var model
    @FocusState private var codeFocused: Bool
    let isAddingAnotherMac: Bool
    var onPairSuccess: () -> Void = {}

    var body: some View {
        @Bindable var model = model

        Section {
            TextField("8-digit code", text: $model.pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .onChange(of: model.pairingCode) { _, value in
                    model.pairingCode = String(value.filter { $0.isASCII && $0.isNumber }.prefix(8))
                }
            Button(isAddingAnotherMac ? "Add Mac" : "Connect", systemImage: "link.badge.plus") {
                let connectionCount = model.connections.count
                Task {
                    await model.pair()
                    if model.connections.count > connectionCount {
                        onPairSuccess()
                    }
                }
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: .infinity)
            .disabled(model.pairingCode.count != 8 || model.isRefreshing)
            if let error = model.pairingErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(isAddingAnotherMac ? "Add Another Mac" : "Pair with Mac")
        } footer: {
            Text("On the Mac, open usAIge Settings → iPhone Sync → Create Connection. Each Mac uses its own 8-digit code.")
        }
        .task { codeFocused = true }
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
