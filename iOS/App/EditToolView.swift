import SwiftUI

struct EditToolView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let toolID: UUID
    let onSaved: (UUID) -> Void
    @State private var name: String
    @State private var endpoint: String
    @State private var replacementToken = ""
    @State private var removeSavedToken = false
    @State private var refreshInterval: Int
    @State private var isTesting = false
    @State private var testError: String?

    init(
        tool: RemoteToolConfiguration,
        onSaved: @escaping (UUID) -> Void = { _ in }
    ) {
        toolID = tool.id
        self.onSaved = onSaved
        _name = State(initialValue: tool.name)
        _endpoint = State(initialValue: tool.endpointURL.absoluteString)
        _refreshInterval = State(initialValue: tool.refreshIntervalMinutes)
    }

    private var validatedURL: URL? {
        guard let url = URL(
            string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ), RemoteToolConfiguration.isSupportedEndpoint(url) else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textContentType(.organizationName)

                TextField("Limits endpoint", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("New bearer token", text: $replacementToken)
                    .textContentType(.newPassword)
                    .disabled(removeSavedToken)

                Toggle("Remove saved bearer token", isOn: $removeSavedToken)
                    .onChange(of: removeSavedToken) { _, shouldRemove in
                        if shouldRemove { replacementToken = "" }
                    }
            } header: {
                Text("Connection")
            } footer: {
                Text("Leave the new-token field empty to keep the saved token. If the endpoint host changes, enter a token for the new host or remove the saved token. HTTPS URLs cannot contain credentials, query parameters, or fragments.")
            }

            Section("Refresh") {
                Picker("Minimum interval", selection: $refreshInterval) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
            }

            if let testError {
                Section {
                    Label(testError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Connection failed: \(testError)")
                }
            }
        }
        .navigationTitle("Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isTesting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isTesting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    testAndSave()
                } label: {
                    if isTesting {
                        ProgressView()
                            .accessibilityLabel("Testing connection")
                    } else {
                        Text("Test & Save")
                    }
                }
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || validatedURL == nil
                        || isTesting
                        || !model.canStartToolMutation
                )
            }
        }
    }

    private func testAndSave() {
        guard let validatedURL else { return }
        isTesting = true
        testError = nil

        Task {
            do {
                let replacementID = try await model.testAndUpdateTool(
                    toolID: toolID,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    endpointURL: validatedURL,
                    replacementBearerToken: replacementToken,
                    removeSavedToken: removeSavedToken,
                    refreshIntervalMinutes: refreshInterval
                )
                dismiss()
                onSaved(replacementID)
            } catch {
                testError = error.localizedDescription
                isTesting = false
            }
        }
    }
}
