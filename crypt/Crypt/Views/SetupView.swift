import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var store: MailStore
    /// Set when adding a second account: shows Cancel and is called when done.
    var onClose: (() -> Void)?

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var provider = MailProvider.all[0]
    @State private var providerTouched = false
    @State private var showServers = false
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @State private var smtpSecurity = SMTPSecurity.startTLS
    @State private var saveSent = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    providerPicker
                    VStack(spacing: 22) {
                        InscribedField(label: "Your name", text: $name, prompt: "As it appears on your letters", contentType: .name)
                        InscribedField(label: "Email", text: $email, prompt: "you@icloud.com", keyboard: .emailAddress, contentType: .emailAddress)
                        InscribedField(label: "App password", text: $password, prompt: "Not your normal password", secure: true, contentType: .password)
                        Text(provider.passwordHint)
                            .font(Theme.serifItalic(14))
                            .foregroundStyle(Theme.ash)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    serverSection
                    if let error {
                        Text(error)
                            .font(Theme.serif(15))
                            .foregroundStyle(Theme.ember)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Theme.crimson.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack(spacing: 10) {
                            if working { ProgressView().tint(Theme.bone) }
                            Text(working ? "Opening the gates…" : (onClose == nil ? "Enter the Crypt" : "Add this account"))
                        }
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    .disabled(working || !canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)

                    Text("Your password stays in this iPhone's Keychain. Crypt talks only to your mail provider.")
                        .font(Theme.serifItalic(13))
                        .foregroundStyle(Theme.ash.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .topLeading) {
            if let onClose {
                Button("Cancel", action: onClose)
                    .font(Theme.engraved(14))
                    .foregroundStyle(Theme.ash)
                    .padding()
                    .disabled(working)
            }
        }
        .onAppear { apply(provider) }
        .onChange(of: email) { _, value in
            guard !providerTouched, let guess = MailProvider.guess(for: value), guess != provider else { return }
            provider = guess
            apply(guess)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("✠")
                .font(.system(size: 26))
                .foregroundStyle(Theme.blood)
                .shadow(color: Theme.blood, radius: 12)
            Text(onClose == nil ? "Crypt" : "Another Soul")
                .font(Theme.gothic(onClose == nil ? 72 : 52))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Theme.crimson, radius: 18)
            Text("LETTERS FROM THE DARK")
                .font(Theme.engraved(12))
                .tracking(4)
                .foregroundStyle(Theme.ash)
            OrnamentDivider()
                .padding(.top, 10)
        }
        .padding(.top, 20)
    }

    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MailProvider.all) { item in
                    Button {
                        provider = item
                        providerTouched = true
                        apply(item)
                    } label: {
                        Text(item.name)
                            .font(Theme.engraved(13))
                            .foregroundStyle(item == provider ? Theme.bone : Theme.ash)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(item == provider ? Theme.crimson : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(item == provider ? Theme.blood : Theme.line))
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                withAnimation { showServers.toggle() }
            } label: {
                HStack {
                    Text("SERVER SETTINGS")
                        .font(Theme.engraved(12))
                        .tracking(2)
                    Spacer()
                    Image(systemName: showServers ? "chevron.up" : "chevron.down")
                }
                .foregroundStyle(Theme.ash)
            }
            if showServers || provider.id == "custom" {
                InscribedField(label: "User name (if not your email)", text: $username, prompt: "Usually blank")
                HStack(spacing: 16) {
                    InscribedField(label: "Incoming (IMAP)", text: $imapHost, prompt: "imap.example.com", keyboard: .URL)
                    InscribedField(label: "Port", text: $imapPort, keyboard: .numberPad)
                        .frame(width: 70)
                }
                HStack(spacing: 16) {
                    InscribedField(label: "Outgoing (SMTP)", text: $smtpHost, prompt: "smtp.example.com", keyboard: .URL)
                    InscribedField(label: "Port", text: $smtpPort, keyboard: .numberPad)
                        .frame(width: 70)
                }
                Picker("Outgoing security", selection: $smtpSecurity) {
                    ForEach(SMTPSecurity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $saveSent) {
                    Text("Save a copy in Sent")
                        .font(Theme.serif(16))
                        .foregroundStyle(Theme.bone)
                }
                .tint(Theme.crimson)
            }
        }
        .padding(16)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !imapHost.isEmpty && !smtpHost.isEmpty
    }

    private func apply(_ provider: MailProvider) {
        guard provider.id != "custom" else { return }
        imapHost = provider.imapHost
        imapPort = "993"
        smtpHost = provider.smtpHost
        smtpPort = String(provider.smtpPort)
        smtpSecurity = provider.smtpSecurity
        saveSent = provider.saveSentCopy
    }

    private func signIn() async {
        working = true
        error = nil
        defer { working = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        var account = MailAccount()
        account.displayName = name.trimmingCharacters(in: .whitespaces)
        account.email = trimmedEmail
        account.username = username.trimmingCharacters(in: .whitespaces)
        account.imapHost = imapHost.trimmingCharacters(in: .whitespaces)
        account.imapPort = Int(imapPort) ?? 993
        account.smtpHost = smtpHost.trimmingCharacters(in: .whitespaces)
        account.smtpPort = Int(smtpPort) ?? 587
        account.smtpSecurity = smtpSecurity
        account.saveSentCopy = saveSent
        do {
            try await store.addAccount(account, password: password.trimmingCharacters(in: .whitespaces))
            onClose?()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
