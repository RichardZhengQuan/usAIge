import Foundation
import SwiftUI

struct ToolsView: View {
    @Environment(RelayAppModel.self) private var model
    @SceneStorage("connection.expandedMacIDs") private var storedExpandedMacIDs = ""
    @State private var macToDisconnect: MacConnectionSummary?
    @State private var disconnectingMacIDs: Set<UUID> = []

    #if DEBUG
    @State private var demoMacs: [MacConnectionSummary] = UsageDemoData.isEnabled
        ? UsageDemoData.macSections().map { mac in
            MacConnectionSummary(
                id: mac.id,
                name: mac.name,
                limitCount: mac.snapshots.count,
                updatedAt: mac.updatedAt,
                errorMessage: nil
            )
        }
        : []
    #endif

    var body: some View {
        let macs = displayedMacs
        let macIDs = macs.map(\.id)

        Group {
            if macs.isEmpty {
                Form {
                    MacPairingSection(isAddingAnotherMac: false)
                    privacySection
                }
            } else {
                connectedMacs(macs)
            }
        }
        .animation(.snappy, value: macIDs)
        .onChange(of: macIDs) { previous, current in
            let removed = Set(previous).subtracting(current)
            if !removed.isEmpty {
                expandedMacIDs.subtract(removed.map(\.uuidString))
            }
        }
        .confirmationDialog(
            "Disconnect \(macToDisconnect?.name ?? "")?",
            isPresented: Binding(
                get: { macToDisconnect != nil },
                set: { if !$0 { macToDisconnect = nil } }
            ),
            titleVisibility: .visible,
            presenting: macToDisconnect
        ) { mac in
            Button("Disconnect", role: .destructive) { disconnect(mac.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its limits leave this iPhone and its Apple Watch. Other Macs stay connected.")
        }
        .navigationTitle("Connection")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if !macs.isEmpty {
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

    private func connectedMacs(_ macs: [MacConnectionSummary]) -> some View {
        let expanded = expandedMacIDs
        let isRefreshing = !isShowingDemo && model.isRefreshing

        return List {
            Section("Connected Macs") {
                ForEach(macs) { mac in
                    MacConnectionRow(
                        mac: mac,
                        isExpanded: expanded.contains(mac.id.uuidString),
                        isRefreshing: isRefreshing,
                        isDisconnecting: disconnectingMacIDs.contains(mac.id),
                        toggleExpansion: {
                            withAnimation(.snappy) {
                                expandedMacIDs.formSymmetricDifference([mac.id.uuidString])
                            }
                        },
                        refresh: { refresh(mac.id) },
                        requestDisconnect: { macToDisconnect = mac }
                    )
                }
            }
            privacySection
        }
        .listStyle(.insetGrouped)
    }

    private var privacySection: some View {
        Section {
            Label("Only normalized limit percentages and reset times are synced.", systemImage: "lock.shield")
        } footer: {
            Text("Provider credentials never reach the relay or this iPhone. Each Mac can be disconnected independently.")
        }
    }

    private var expandedMacIDs: Set<String> {
        get { Set(storedExpandedMacIDs.split(separator: ",").map(String.init)) }
        nonmutating set { storedExpandedMacIDs = newValue.sorted().joined(separator: ",") }
    }

    private var displayedMacs: [MacConnectionSummary] {
        #if DEBUG
        if isShowingDemo { return demoMacs }
        #endif
        return model.connectionStates.map { state in
            MacConnectionSummary(
                id: state.connection.channelID,
                name: state.connection.macName,
                limitCount: state.snapshots.count,
                updatedAt: state.serverReceivedAt,
                errorMessage: model.errorMessage(for: state.connection.channelID)
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

    private func refresh(_ id: UUID) {
        guard !isShowingDemo else { return }
        Task { await model.refresh(connectionID: id) }
    }

    private func disconnect(_ id: UUID) {
        #if DEBUG
        if isShowingDemo {
            demoMacs.removeAll { $0.id == id }
            return
        }
        #endif
        guard disconnectingMacIDs.insert(id).inserted else { return }
        Task {
            await model.disconnect(connectionID: id)
            disconnectingMacIDs.remove(id)
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
            .usaigeProminentButtonStyle()
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

private struct MacConnectionSummary: Identifiable {
    let id: UUID
    let name: String
    let limitCount: Int
    let updatedAt: Date?
    let errorMessage: String?
}

private struct MacConnectionRow: View {
    let mac: MacConnectionSummary
    let isExpanded: Bool
    let isRefreshing: Bool
    let isDisconnecting: Bool
    let toggleExpansion: () -> Void
    let refresh: () -> Void
    let requestDisconnect: () -> Void

    var body: some View {
        header

        if isExpanded {
            if let error = mac.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
            Button(action: refresh) {
                Label("Refresh Now", systemImage: "arrow.clockwise")
                    .padding(.leading, 20)
            }
            .disabled(isRefreshing || isDisconnecting)

            Button(role: .destructive, action: requestDisconnect) {
                Text("Disconnect This Mac")
                    .foregroundStyle(.red)
                    .padding(.leading, 20)
            }
            .disabled(isDisconnecting)
        }
    }

    private var header: some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.name)
                        status
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: mac.errorMessage == nil
                        ? "laptopcomputer"
                        : "laptopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(mac.errorMessage == nil ? Color.primary : Color.orange)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? Text("expanded") : Text("collapsed"))
        .accessibilityHint("Shows this Mac's actions")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Keep the row in place until the user confirms the disconnect.
            Button("Disconnect", systemImage: "xmark.circle", action: requestDisconnect)
                .tint(.red)
                .disabled(isDisconnecting)
        }
        .contextMenu {
            Button("Disconnect", systemImage: "xmark.circle", role: .destructive, action: requestDisconnect)
                .disabled(isDisconnecting)
        }
    }

    private var status: Text {
        if let updatedAt = mac.updatedAt {
            Text("\(mac.limitCount) limits · Updated \(.currentDate, format: .reference(to: updatedAt, maxFieldCount: 1))")
        } else {
            Text("\(mac.limitCount) limits · Waiting for data")
        }
    }
}
