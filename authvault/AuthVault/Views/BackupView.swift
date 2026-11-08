import SwiftUI
import UniformTypeIdentifiers

private struct ShareItem: Identifiable { let id = UUID(); let url: URL }

struct BackupView: View {
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var status: (ok: Bool, message: String)?
    @State private var busy = false
    @State private var share: ShareItem?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Security") {
                    Toggle("Require Face ID / passcode to open", isOn: $settings.lockEnabled)
                }

                Section {
                    SecureField("Backup passphrase", text: $settings.passphrase)
                } header: {
                    Text("Encryption passphrase")
                } footer: {
                    Text("Backups are encrypted with this. You'll need the same passphrase to restore — keep it safe, it can't be recovered.")
                }

                Section {
                    TextField("https://nas-server.co.uk/webdav/authvault.bak", text: $settings.webdavURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username", text: $settings.webdavUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $settings.webdavPassword)
                    Toggle("Accept self-signed certificate", isOn: $settings.trustSelfSigned)
                    Button { Task { await backup() } } label: { Label("Back up to NAS", systemImage: "arrow.up.to.line") }
                        .disabled(busy || !settings.backupConfigured)
                    Button { Task { await restore() } } label: { Label("Restore from NAS", systemImage: "arrow.down.to.line") }
                        .disabled(busy || !settings.backupConfigured)
                } header: {
                    Text("NAS backup (WebDAV)")
                } footer: {
                    Text("A WebDAV file URL on your NAS (TrueNAS has a WebDAV app). The whole encrypted vault is stored at that path.")
                }

                Section {
                    Button { exportFile() } label: { Label("Export encrypted file\u{2026}", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import encrypted file\u{2026}", systemImage: "square.and.arrow.down") }
                } header: {
                    Text("File")
                } footer: {
                    Text("Save an encrypted backup anywhere (Files, AirDrop), or restore one.")
                }

                if let status {
                    Section {
                        Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(status.ok ? Theme.good : .red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Backup & settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) { if busy { ProgressView() } }
            }
            .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in importFile(result) }
        }
    }

    private func backup() async {
        busy = true; defer { busy = false }
        do {
            let data = try Backup.encrypt(vault.accounts, passphrase: settings.passphrase)
            try await WebDAV.upload(data, to: settings.webdavURL, user: settings.webdavUser, password: settings.webdavPassword)
            status = (true, "Backed up \(vault.accounts.count) account\(vault.accounts.count == 1 ? "" : "s") to your NAS.")
        } catch { status = (false, describeError(error)) }
    }

    private func restore() async {
        busy = true; defer { busy = false }
        do {
            let data = try await WebDAV.download(from: settings.webdavURL, user: settings.webdavUser, password: settings.webdavPassword)
            let accounts = try Backup.decrypt(data, passphrase: settings.passphrase)
            vault.replaceAll(accounts, merge: true)
            status = (true, "Restored — you now have \(vault.accounts.count) account\(vault.accounts.count == 1 ? "" : "s").")
        } catch { status = (false, describeError(error)) }
    }

    private func exportFile() {
        do {
            let data = try Backup.encrypt(vault.accounts, passphrase: settings.passphrase)
            let name = "authvault-\(Int(Date().timeIntervalSince1970)).authvault"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            share = ShareItem(url: url)
        } catch { status = (false, describeError(error)) }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let accounts = try Backup.decrypt(data, passphrase: settings.passphrase)
            vault.replaceAll(accounts, merge: true)
            status = (true, "Imported — you now have \(vault.accounts.count) account\(vault.accounts.count == 1 ? "" : "s").")
        } catch { status = (false, describeError(error)) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
