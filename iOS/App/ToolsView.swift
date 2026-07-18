import SwiftUI

struct ToolsView: View {
    @Environment(RelayAppModel.self) private var model
    @FocusState private var codeFocused: Bool

    var body: some View {
        @Bindable var model = model
        Form {
            if let connection = model.connection {
                Section("Connected Mac") {
                    LabeledContent("Mac", value: connection.macName)
                    LabeledContent("Limits", value: "\(model.snapshots.count)")
                    LabeledContent("Last server update") {
                        if let date = model.serverReceivedAt { Text(date, style: .relative) }
                        else { Text("Not yet").foregroundStyle(.secondary) }
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Button("Refresh Now", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        .disabled(model.isRefreshing)
                }
                Section {
                    Button("Disconnect This iPhone", role: .destructive) { Task { await model.disconnect() } }
                } footer: {
                    Text("The Mac sends only normalized limit percentages and reset times. Provider credentials never reach the relay or this iPhone.")
                }
            } else {
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
                    Button("Connect", systemImage: "link") { Task { await model.pair() } }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(model.pairingCode.count != 8 || model.isRefreshing)
                    if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Pair with Mac")
                } footer: {
                    Text("On your Mac, open usAIge Settings → iPhone Sync → Create Connection. Codes expire after 10 minutes and connect one device.")
                }
            }
        }
        .navigationTitle("Connection")
        .task { if !model.isConnected { codeFocused = true } }
    }
}
