import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0           // 0 scan, 1 manual, 2 paste
    @State private var issuer = ""
    @State private var label = ""
    @State private var secret = ""
    @State private var digits = 6
    @State private var period = 30
    @State private var algorithm: OTPAlgorithm = .sha1
    @State private var pasteURI = ""
    @State private var error: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Method", selection: $mode) {
                    Text("Scan").tag(0); Text("Manual").tag(1); Text("Paste").tag(2)
                }
                .pickerStyle(.segmented)

                switch mode {
                case 0:
                    Section {
                        Button { showScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                    } footer: {
                        Text("Point the camera at the authenticator QR code the website shows you.")
                    }
                case 1:
                    Section("Account") {
                        TextField("Service (e.g. GitHub)", text: $issuer)
                        TextField("Account (e.g. your email)", text: $label).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("Secret key") {
                        TextField("Base32 key", text: $secret)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                    Section("Advanced") {
                        Picker("Digits", selection: $digits) { Text("6").tag(6); Text("8").tag(8) }
                        Stepper("Period: \(period)s", value: $period, in: 15...90, step: 15)
                        Picker("Algorithm", selection: $algorithm) {
                            ForEach(OTPAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                default:
                    Section {
                        TextField("otpauth://totp/...", text: $pasteURI, axis: .vertical)
                            .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                    } header: {
                        Text("Setup link")
                    } footer: {
                        Text("Paste an otpauth:// link (some sites offer it next to the QR code).")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if mode != 0 {
                    ToolbarItem(placement: .confirmationAction) { Button("Add") { addManualOrPaste() } }
                }
            }
            .sheet(isPresented: $showScanner) {
                ScannerSheet { handleURI($0) }
            }
        }
    }

    private func addManualOrPaste() {
        error = nil
        if mode == 2 { handleURI(pasteURI); return }
        let key = secret.replacingOccurrences(of: " ", with: "")
        guard Base32.isValid(key) else { error = "That secret key isn't valid Base32."; return }
        let account = OTPAccount(issuer: issuer.trimmingCharacters(in: .whitespaces),
                                 label: label.trimmingCharacters(in: .whitespaces),
                                 config: TOTPConfig(secret: key, digits: digits, period: period, algorithm: algorithm))
        if vault.add(account) { dismiss() } else { error = "That account is already in your vault." }
    }

    private func handleURI(_ uri: String) {
        error = nil
        guard let account = OTPAuth.parse(uri) else { error = "That isn't a valid authenticator link or QR code."; return }
        if vault.add(account) { dismiss() } else { error = "That account is already in your vault." }
    }
}
