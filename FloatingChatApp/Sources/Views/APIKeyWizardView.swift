import SwiftUI

// MARK: - View model (testable core)

/// Drives the API-key wizard. Auto-enumerates EVERY registered provider, so it
/// always covers all of them (incl. newly added ones) with no per-provider UI
/// code. Keys are stored in the Keychain via KeychainService; key text is
/// cleared from memory after saving.
@MainActor
final class APIKeyWizardModel: ObservableObject {
    enum Status: Equatable {
        case unknown, saved, testing, valid, invalid(String)
    }

    struct Row: Identifiable {
        let id: String          // provider id
        let name: String
        let iconName: String
        let requiresKey: Bool
        let isLocal: Bool
        var keyInput: String
        var hasStoredKey: Bool
        var status: Status
    }

    @Published var rows: [Row] = []

    private let providerManager: ProviderManager
    private let keychain: any KeychainStoring

    init(providerManager: ProviderManager = .shared, keychain: any KeychainStoring = KeychainService.shared) {
        self.providerManager = providerManager
        self.keychain = keychain
        reload()
    }

    func reload() {
        rows = providerManager.availableProviders.map { provider in
            Row(
                id: provider.id,
                name: provider.name,
                iconName: provider.iconName,
                requiresKey: provider.requiresAPIKey,
                isLocal: provider.isLocal,
                keyInput: "",
                hasStoredKey: !provider.requiresAPIKey || keychain.exists(key: provider.apiKeySettingKey),
                status: .unknown
            )
        }
    }

    /// At least one provider is usable (local, or has a stored key).
    var hasAnyUsableProvider: Bool {
        rows.contains { !$0.requiresKey || $0.hasStoredKey }
    }

    private func provider(_ id: String) -> (any AIProvider)? {
        providerManager.availableProviders.first { $0.id == id }
    }

    func saveKey(for id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }),
              let provider = provider(id) else { return }
        let key = rows[idx].keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keychain.save(key: provider.apiKeySettingKey, value: key)
            rows[idx].hasStoredKey = true
            rows[idx].status = .saved
            rows[idx].keyInput = ""   // never keep the secret around after saving
        } catch {
            rows[idx].status = .invalid("Couldn't save: \(error.localizedDescription)")
        }
    }

    func clearKey(for id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }),
              let provider = provider(id) else { return }
        do {
            try keychain.delete(key: provider.apiKeySettingKey)
            rows[idx].hasStoredKey = false
            rows[idx].status = .unknown
        } catch {
            // Don't claim it's gone if the delete failed (Codex LOW).
            rows[idx].status = .invalid("Couldn't clear: \(error.localizedDescription)")
        }
    }

    /// REAL end-to-end test: persist the typed key (so the provider, which reads
    /// the Keychain, can use it) then make a tiny live request. This actually
    /// confirms the key works — not just that it's a non-empty/format-valid
    /// string (Codex MED). Note: the provider reads KeychainService.shared.
    func test(id: String) async {
        guard let idx = rows.firstIndex(where: { $0.id == id }),
              let provider = provider(id) else { return }

        // A live test inherently uses the SHARED keychain, because the provider
        // instance reads its key from KeychainService.shared. (The injected
        // `keychain` is only for offline unit-testing of save/clear/reload.)
        let liveKeychain = KeychainService.shared
        let typed = rows[idx].keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            do { try liveKeychain.save(key: provider.apiKeySettingKey, value: typed) } catch {
                rows[idx].status = .invalid("Couldn't save key to test: \(error.localizedDescription)")
                return
            }
            // Mirror into the injected store too so reload/UI stay consistent.
            try? keychain.save(key: provider.apiKeySettingKey, value: typed)
            rows[idx].hasStoredKey = true
            rows[idx].keyInput = ""
        }
        guard liveKeychain.exists(key: provider.apiKeySettingKey) else {
            rows[idx].status = .invalid("No key to test (save it first)")
            return
        }

        rows[idx].status = .testing
        do {
            var settings = ModelSettings()
            settings.maxTokens = 1
            let stream = try await provider.sendMessage(
                messages: [ChatMessage(role: .user, content: "ping")],
                settings: settings,
                stream: false
            )
            for try await _ in stream { break }   // any successful chunk = reachable
            rows[idx].status = .valid
        } catch let error as AIProviderError {
            rows[idx].status = .invalid(error.localizedDescription)
        } catch {
            rows[idx].status = .invalid(error.localizedDescription)
        }
    }
}

// MARK: - View

struct APIKeyWizardView: View {
    @StateObject private var model = APIKeyWizardModel()
    let onClose: () -> Void

    private let darkBg = Color(red: 0.10, green: 0.10, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.rows) { $row in
                        providerRow($row)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(darkBg)
    }

    private var header: some View {
        HStack {
            Image(systemName: "key.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Provider Keys").font(.headline)
                Text("Add a key for any provider to start chatting. Keys are stored in your macOS Keychain.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Done", action: onClose).buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func providerRow(_ row: Binding<APIKeyWizardModel.Row>) -> some View {
        let r = row.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: r.iconName).frame(width: 18)
                Text(r.name).font(.system(size: 13, weight: .semibold))
                statusBadge(r)
                Spacer()
                if r.isLocal {
                    Text("No key needed").font(.caption).foregroundColor(.secondary)
                }
            }
            if r.requiresKey {
                HStack(spacing: 6) {
                    SecureField(r.hasStoredKey ? "•••••• (saved — type to replace)" : "Paste \(r.name) API key",
                                text: row.keyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { model.saveKey(for: r.id) }
                        .disabled(r.keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test") { Task { await model.test(id: r.id) } }
                        .disabled(!r.hasStoredKey && r.keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if r.hasStoredKey {
                        Button(role: .destructive) { model.clearKey(for: r.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func statusBadge(_ r: APIKeyWizardModel.Row) -> some View {
        switch r.status {
        case .unknown:
            if r.hasStoredKey {
                Label("Saved", systemImage: "checkmark.circle").font(.caption2).foregroundColor(.green)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill").font(.caption2).foregroundColor(.green)
        case .testing:
            Label("Testing…", systemImage: "clock").font(.caption2).foregroundColor(.secondary)
        case .valid:
            Label("Valid", systemImage: "checkmark.seal.fill").font(.caption2).foregroundColor(.green)
        case .invalid(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundColor(.orange)
        }
    }
}
