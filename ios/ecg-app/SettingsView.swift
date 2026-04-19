import SwiftUI

struct SettingsView: View {
    @State private var urlOverride: String = AppConfig.baseURLOverride ?? ""
    @State private var statusText: String = "—"
    @State private var testing = false

    var body: some View {
        NavigationStack {
            List {
                backendSection
                backendStatusSection
            }
            .navigationTitle("Settings")
        }
    }

    private var backendSection: some View {
        Section("Backend") {
            LabeledContent("Active URL") {
                Text(AppConfig.baseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            TextField("Override URL (blank = default)", text: $urlOverride)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
            HStack {
                Button("Save") { saveOverride() }
                Spacer()
                Button("Reset", role: .destructive) {
                    urlOverride = ""
                    AppConfig.setOverride(nil)
                }
                .disabled(AppConfig.baseURLOverride == nil)
            }
        }
    }

    private var backendStatusSection: some View {
        Section("Status") {
            LabeledContent("Model", value: statusText)
            Button {
                Task { await testConnection() }
            } label: {
                if testing {
                    HStack { ProgressView(); Text("Testing…") }
                } else {
                    Text("Test connection")
                }
            }
            .disabled(testing)
        }
    }

    private func saveOverride() {
        let trimmed = urlOverride.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            AppConfig.setOverride(nil)
        } else if let url = URL(string: trimmed), url.scheme != nil {
            AppConfig.setOverride(url)
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let status = try await APIClient.shared.modelStatus()
            if let err = status.error, !err.isEmpty {
                statusText = "\(status.status) — \(err)"
            } else {
                statusText = status.status
            }
        } catch {
            statusText = error.localizedDescription
        }
    }
}
