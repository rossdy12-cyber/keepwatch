import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: PortalStore
    @State private var draftAddress = ""
    @State private var confirmSignOut = false
    @State private var signedOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://nas-server.co.uk", text: $draftAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    if draftAddress != store.trueNASAddress {
                        Button("Save address", action: save)
                            .disabled(PortalStore.url(from: draftAddress) == nil)
                    }
                } header: {
                    Text("TrueNAS address")
                } footer: {
                    Text("Opens in the TrueNAS tab. Use your domain, or https:// plus the NAS's Tailscale IP (with Tailscale on).")
                }

                Section {
                    Toggle("Accept self-signed certificates", isOn: $store.acceptSelfSigned)
                } footer: {
                    Text("Only for home and Tailscale addresses (192.168.x.x, 10.x.x.x, 100.x.x.x, .local, .ts.net). TrueNAS uses a self-signed certificate on those. Public websites are always checked.")
                }

                OTPSection()

                Section {
                    NavigationLink {
                        TransferView()
                    } label: {
                        Label("Move 2FA codes to Vaultwarden", systemImage: "arrow.right.doc.on.clipboard")
                    }
                } footer: {
                    Text("Reads Google Authenticator's export QR codes and turns the accounts you choose into something Vaultwarden can import.")
                }

                Section {
                    Button("Sign out of everything", role: .destructive) { confirmSignOut = true }
                    if signedOut {
                        Label("Signed out. Pages will ask you to sign in again.", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } footer: {
                    Text("Your sign-ins (TrueNAS, Authelia and each app) are kept on this iPhone so you don't have to sign in every time. This clears them.")
                }
            }
            .scrollContentBackground(.hidden)
            .portalChrome()
            .navigationTitle("Settings")
            .onAppear { draftAddress = store.trueNASAddress }
            .confirmationDialog("Sign out of TrueNAS and every app?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                            modifiedSince: .distantPast) {
                        signedOut = true
                    }
                }
            }
        }
    }

    private func save() {
        guard PortalStore.url(from: draftAddress) != nil else { return }
        store.trueNASAddress = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        draftAddress = store.trueNASAddress
    }
}
