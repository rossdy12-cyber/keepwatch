import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Move 2FA codes to Vaultwarden. Reads Google Authenticator export QR codes (or ordinary 2FA QR codes)
/// from screenshots, lets you choose which accounts to move, and hands them to Vaultwarden either one at a time
/// (copy, then paste into a login's Authenticator key) or as an import file. Everything stays on the phone.
struct TransferView: View {
    @State private var photos: [PhotosPickerItem] = []
    @State private var accounts: [TransferAccount] = []
    @State private var selected: Set<String> = []
    @State private var status: String?
    @State private var exportURL: URL?
    @State private var copiedID: String?
    @ObservedObject private var vault = OTPVault.shared

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $photos, matching: .images) {
                    Label(accounts.isEmpty ? "Choose export screenshots" : "Add more screenshots", systemImage: "qrcode.viewfinder")
                }
                if let status {
                    Text(status).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            } footer: {
                Text("In Google Authenticator: ⋮ → Transfer accounts → Export accounts, choose the accounts, and screenshot each QR code it shows. Ordinary 2FA QR codes (from a website's setup page) work too. Nothing is uploaded anywhere.")
            }

            if !accounts.isEmpty {
                Section {
                    ForEach(accounts) { account in
                        row(account)
                    }
                } header: {
                    HStack {
                        Text("\(selected.count) of \(accounts.count) selected")
                        Spacer()
                        Button(selected.count == accounts.count ? "None" : "All") {
                            selected = selected.count == accounts.count ? [] : Set(accounts.filter(\.isTOTP).map(\.id))
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Untick anything that should stay out of Vaultwarden (Vaultwarden itself, email, banking, TrueNAS). Tap the copy button to paste a code into an existing login in the Bitwarden app: edit the login → Authenticator key → paste.")
                }

                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Save the import file (\(selected.count) accounts)", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        let existing = Set(vault.accounts.map { $0.secret.uppercased() })
                        let new = accounts.filter { selected.contains($0.id) && !existing.contains($0.secretBase32) }
                        vault.accounts += new.map(\.asOTPAccount)
                        status = "Added \(new.count) to NAS Portal's own codes. Set each one's site in Settings to fill it in automatically."
                    } label: {
                        Label("Also keep them in NAS Portal", systemImage: "key")
                    }
                    .disabled(selected.isEmpty)
                    Button("Forget these accounts", role: .destructive, action: clear)
                } footer: {
                    Text("The import file creates a new login for each account. In the Vaultwarden web vault (https://vw.nas-server.co.uk): Tools → Import data → File format \"Bitwarden (csv)\" → choose the file. Logins you already have won't be merged, so for those use the copy button instead. Delete the file from Files afterwards: it holds your secrets unencrypted.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .portalChrome()
        .navigationTitle("Move 2FA to Vaultwarden")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photos) { items in
            guard !items.isEmpty else { return }
            Task { await read(items) }
        }
        .onChange(of: selected) { _ in writeExport() }
        .onDisappear(perform: clear)
    }

    private func row(_ account: TransferAccount) -> some View {
        HStack(spacing: 12) {
            Button {
                if selected.contains(account.id) { selected.remove(account.id) } else if account.isTOTP { selected.insert(account.id) }
            } label: {
                Image(systemName: selected.contains(account.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(account.id) ? Theme.accent : Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(!account.isTOTP)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).foregroundStyle(.white)
                Text(account.isTOTP ? account.username : "Counter-based code: Vaultwarden can't use these")
                    .font(.caption)
                    .foregroundStyle(account.isTOTP ? Theme.secondaryText : Theme.warning)
                    .lineLimit(1)
            }
            Spacer()
            if account.isTOTP {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(OTPCodeLabel.format(account.asOTPAccount.code(at: context.date) ?? ""))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
                Button {
                    copy(account)
                } label: {
                    Image(systemName: copiedID == account.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(account.title) for Vaultwarden")
            }
        }
    }

    private func read(_ items: [PhotosPickerItem]) async {
        var found = 0
        var unreadable = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { unreadable += 1; continue }
            let texts = QRReader.readAll(data)
            if texts.isEmpty { unreadable += 1 }
            for text in texts {
                for account in OTPTransfer.accounts(from: text) where !accounts.contains(where: { $0.id == account.id }) {
                    accounts.append(account)
                    if account.isTOTP { selected.insert(account.id) }
                    found += 1
                }
            }
        }
        photos = []
        var parts = ["Found \(found) new account\(found == 1 ? "" : "s")."]
        if unreadable > 0 { parts.append("\(unreadable) picture\(unreadable == 1 ? " had" : "s had") no readable QR code; crop closer and try again.") }
        status = parts.joined(separator: " ")
        writeExport()
    }

    /// Copies the otpauth:// link (kept on this phone only, and cleared after 2 minutes).
    private func copy(_ account: TransferAccount) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: account.otpauthURI]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copiedID = account.id
    }

    private func writeExport() {
        removeExport()
        let chosen = accounts.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vaultwarden-2fa-import.csv")
        do {
            try OTPTransfer.bitwardenCSV(chosen).write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            exportURL = url
        } catch {
            status = "Couldn't create the import file: \(error.localizedDescription)"
        }
    }

    private func removeExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    private func clear() {
        removeExport()
        accounts = []
        selected = []
        status = nil
        copiedID = nil
    }
}
