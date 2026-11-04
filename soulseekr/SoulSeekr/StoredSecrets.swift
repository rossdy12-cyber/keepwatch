import Security
import SwiftUI
import UIKit

/// Passwords and keys for the NAS services. Typed in once on this iPhone and kept in its Keychain, never in the code.
enum StoredSecret: String, CaseIterable, Identifiable {
    case hearrPin, slskdPassword, slskdApiKey, lidarrApiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hearrPin: return "Hearr PIN"
        case .slskdPassword: return "slskd password"
        case .slskdApiKey: return "slskd API key"
        case .lidarrApiKey: return "Lidarr API key"
        }
    }

    private var account: String { "secret." + rawValue }

    var value: String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func save(_ newValue: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard !newValue.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(newValue.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Where the keys are typed in.
struct SecretsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var values: [StoredSecret: String] = Dictionary(uniqueKeysWithValues: StoredSecret.allCases.map { ($0, $0.value) })

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(StoredSecret.allCases) { secret in
                        SecureField(secret.title, text: Binding(get: { values[secret] ?? "" }, set: { values[secret] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Kept only in this iPhone's Keychain. The API keys are in each app's Settings → General → Security.")
                }
            }
            .navigationTitle("Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for secret in StoredSecret.allCases { secret.save(values[secret] ?? "") }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Copies a stored password; asks for it first if it hasn't been typed in yet. Long-press to change it.
struct SecretCopyButton: View {
    let secret: StoredSecret
    let label: String
    @State private var editing = false

    var body: some View {
        Button(label) {
            let value = secret.value
            if value.isEmpty { editing = true } else { UIPasteboard.general.string = value }
        }
        .contextMenu { Button("Change keys…") { editing = true } }
        .sheet(isPresented: $editing) { SecretsSheet() }
    }
}
