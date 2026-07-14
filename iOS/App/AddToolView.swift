import SwiftUI

struct AddToolView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var refreshInterval = 15
    @State private var isTesting = false
    @State private var testError: String?

    private var validatedURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              RemoteToolConfiguration.isSupportedEndpoint(url) else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Claude Team"))
                    .textContentType(.organizationName)

                TextField("Limits endpoint", text: $endpoint, prompt: Text("https://example.com/api/limits"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("Bearer token (optional)", text: $token)
                    .textContentType(.password)
            } header: {
                Text("Tool")
            } footer: {
                Text("Use an HTTPS URL without embedded credentials, query parameters, or fragments. Put secrets in the bearer-token field so they stay in Keychain.")
            }

            Section {
                Picker("Minimum interval", selection: $refreshInterval) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("The app refreshes immediately when opened. iOS may delay background work to protect battery life.")
            }

            Section("Expected response") {
                Text("The endpoint must return JSON with a limits array. Each limit includes an ID, name, used or remaining percentage, and an optional reset time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                NavigationLink("View JSON example") {
                    EndpointFormatView()
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
        .navigationTitle("Add AI Tool")
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
                        Text("Test & Add")
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validatedURL == nil || isTesting)
                .disabled(!model.canStartToolMutation)
            }
        }
    }

    private func testAndSave() {
        guard let validatedURL else { return }
        isTesting = true
        testError = nil
        Task {
            do {
                try await model.testAndAddTool(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    endpointURL: validatedURL,
                    bearerToken: token,
                    refreshIntervalMinutes: refreshInterval
                )
                dismiss()
            } catch {
                testError = error.localizedDescription
                isTesting = false
            }
        }
    }
}

private struct EndpointFormatView: View {
    private let example = #"""
    {
      "schemaVersion": 1,
      "limits": [{
        "id": "five-hour",
        "name": "5-hour limit",
        "usedPercent": 42,
        "resetAt": "2026-07-14T12:00:00Z",
        "windowMinutes": 300,
        "plan": "Team"
      }]
    }
    """#

    var body: some View {
        ScrollView {
            Text(example)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("JSON Format")
        .navigationBarTitleDisplayMode(.inline)
    }
}
