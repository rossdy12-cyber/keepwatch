import CoreImage
import PhotosUI
import SwiftUI

/// Settings → Two-factor codes.
struct OTPSection: View {
    @ObservedObject private var vault = OTPVault.shared
    @State private var editing: OTPAccount?

    var body: some View {
        Section {
            Toggle("Fill codes automatically", isOn: $vault.autoFill)
            ForEach(vault.accounts) { account in
                Button {
                    editing = account
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).foregroundStyle(.white)
                            Text(account.sites.isEmpty ? "No site set" : account.sites)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                Text(OTPCodeLabel.format(account.code(at: context.date) ?? "------"))
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                Text("\(account.secondsLeft(at: context.date))s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .onDelete { vault.accounts.remove(atOffsets: $0) }
            Button {
                editing = OTPAccount(name: "", secret: "", sites: "")
            } label: {
                Label("Add a 2FA code", systemImage: "plus")
            }
        } header: {
            Text("Two-factor codes")
        } footer: {
            Text("NAS Portal makes the same 6-digit codes as your authenticator app and types them into the TrueNAS and Authelia sign-in pages, so you don't have to switch apps. The secrets stay in this iPhone's Keychain. Keeping them here means one phone holds both your password and your codes.")
        }
        .sheet(item: $editing) { account in
            OTPEditor(account: account) { saved in
                if let index = vault.accounts.firstIndex(where: { $0.id == saved.id }) {
                    vault.accounts[index] = saved
                } else {
                    vault.accounts.append(saved)
                }
            }
        }
    }
}

enum OTPCodeLabel {
    /// "123456" → "123 456"
    static func format(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

struct OTPEditor: View {
    @State var account: OTPAccount
    var onSave: (OTPAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Read the QR code from a screenshot", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        if let text = UIPasteboard.general.string { use(text) }
                    } label: {
                        Label("Paste secret or otpauth:// link", systemImage: "doc.on.clipboard")
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                } footer: {
                    Text("Take a screenshot of the QR code TrueNAS or Authelia shows when you set up (or renew) 2FA, then pick it here. Scan the same QR code with your authenticator app too, so both keep working.")
                }
                Section {
                    TextField("Name, e.g. TrueNAS", text: $account.name)
                    TextField("Secret (letters A–Z and 2–7)", text: $account.secret)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("Sites, e.g. nas-server.co.uk", text: $account.sites)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Sites: the addresses whose sign-in page needs this code, comma-separated. TrueNAS: nas-server.co.uk, 100.85.127.42. Authelia: auth.nas-server.co.uk.")
                }
                if let code = account.code() {
                    Section("Current code") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                Text(OTPCodeLabel.format(account.code(at: context.date) ?? code))
                                    .font(.system(.title2, design: .monospaced).weight(.bold))
                                    .foregroundStyle(Theme.accent)
                                Spacer()
                                Text("\(account.secondsLeft(at: context.date))s").foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Text("This should match your authenticator app.").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .portalChrome()
            .navigationTitle(account.name.isEmpty ? "2FA code" : account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        account.name = account.name.trimmingCharacters(in: .whitespaces)
                        account.secret = account.secret.uppercased().filter { !" -=".contains($0) }
                        onSave(account)
                        dismiss()
                    }
                    .disabled(account.name.trimmingCharacters(in: .whitespaces).isEmpty || account.code() == nil
                              || account.siteList.isEmpty)
                }
            }
            .onChange(of: photo) { item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    if let data, let text = QRReader.read(data) {
                        use(text)
                    } else {
                        message = "No QR code found in that picture. Crop the screenshot closer to the code and try again."
                    }
                    photo = nil
                }
            }
        }
    }

    private func use(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = OTPAccount.from(otpauth: trimmed) {
            account.secret = parsed.secret.uppercased()
            account.digits = parsed.digits
            account.period = parsed.period
            account.algorithm = parsed.algorithm
            if account.name.isEmpty { account.name = parsed.name }
            message = "Read the code for \(parsed.name.isEmpty ? "this account" : parsed.name)."
        } else if Base32.decode(trimmed) != nil {
            account.secret = trimmed.uppercased().filter { !" -=".contains($0) }
            message = "Secret pasted."
        } else {
            message = "That isn't a 2FA secret or otpauth:// link."
            return
        }
        if account.sites.isEmpty {
            let lower = trimmed.lowercased()
            account.sites = lower.contains("authelia") ? "auth.nas-server.co.uk" : "nas-server.co.uk, 100.85.127.42"
        }
    }
}

enum QRReader {
    static func read(_ imageData: Data) -> String? {
        guard let image = CIImage(data: imageData),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        let features = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
        return features.compactMap(\.messageString).first { $0.lowercased().hasPrefix("otpauth://") }
            ?? features.first?.messageString
    }
}
