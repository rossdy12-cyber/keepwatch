import SwiftUI

struct MailboxListView: View {
    @EnvironmentObject private var store: MailStore
    @EnvironmentObject private var push: PushManager
    @Environment(\.dismiss) private var dismiss
    @State private var addingAccount = false
    @State private var accountToRemove: MailAccount?

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    accountsSection
                    mailboxesSection
                    settingsSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("The Crypt")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.engraved(14))
                }
            }
            .confirmationDialog(
                "Remove \(accountToRemove?.email ?? "this account") from Crypt? Its mail stays on the server.",
                isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove account", role: .destructive) {
                    if let account = accountToRemove {
                        Task { await store.removeAccount(account.id) }
                    }
                    accountToRemove = nil
                }
            }
            .fullScreenCover(isPresented: $addingAccount) {
                SetupView(onClose: { addingAccount = false })
                    .environmentObject(store)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.engraved(12))
            .tracking(2)
            .foregroundStyle(Theme.ash)
    }

    private var accountsSection: some View {
        Section {
            ForEach(store.accounts) { account in
                let active = account.id == store.activeID
                Button {
                    Task { await store.switchTo(account.id) }
                    if !active { dismiss() }
                } label: {
                    HStack(spacing: 12) {
                        Sigil(name: account.label, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                                .font(Theme.serif(17, weight: active ? .semibold : .regular))
                                .foregroundStyle(Theme.bone)
                                .lineLimit(1)
                            if account.label != account.email {
                                Text(account.email)
                                    .font(Theme.serifItalic(13))
                                    .foregroundStyle(Theme.ash)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if let unread = store.unreadCounts[account.id], unread > 0 {
                            Text("\(unread)")
                                .font(Theme.engraved(12))
                                .foregroundStyle(Theme.bone)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.crimson, in: Capsule())
                        }
                        if active {
                            Text("✠").foregroundStyle(Theme.blood)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(active ? Theme.crimson.opacity(0.22) : Theme.surface)
                .swipeActions {
                    Button(role: .destructive) {
                        accountToRemove = account
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .tint(Theme.crimson)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        accountToRemove = account
                    } label: {
                        Label("Remove account", systemImage: "trash")
                    }
                }
            }
            Button {
                addingAccount = true
            } label: {
                Label {
                    Text("Add account").font(Theme.engraved(14))
                } icon: {
                    Image(systemName: "plus.circle")
                }
                .foregroundStyle(Theme.ember)
            }
            .listRowBackground(Theme.surface)
        } header: {
            sectionHeader("ACCOUNTS")
        } footer: {
            if store.accounts.count > 1 {
                Text("Swipe left on an account to remove it.")
                    .font(Theme.serifItalic(12))
                    .foregroundStyle(Theme.ash.opacity(0.7))
            }
        }
    }

    private var mailboxesSection: some View {
        Section {
            ForEach(store.mailboxes) { mailbox in
                let current = mailbox.path == store.currentMailbox?.path
                Button {
                    Task { await store.select(mailbox) }
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: mailbox.symbol)
                            .frame(width: 24)
                            .foregroundStyle(Theme.blood)
                        Text(mailbox.displayName)
                            .font(Theme.serif(18, weight: current ? .semibold : .regular))
                            .foregroundStyle(Theme.bone)
                        Spacer()
                        if current {
                            Text("✠").foregroundStyle(Theme.blood)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(current ? Theme.crimson.opacity(0.22) : Color.clear)
                .listRowSeparatorTint(Theme.line)
            }
        } header: {
            sectionHeader("MAILBOXES" + (store.accounts.count > 1 ? " · \(store.account?.label.uppercased() ?? "")" : ""))
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                NotificationsView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: push.enabled ? "bell.badge.fill" : "bell.slash")
                        .frame(width: 24)
                        .foregroundStyle(Theme.blood)
                    Text("Notifications")
                        .font(Theme.serif(18))
                        .foregroundStyle(Theme.bone)
                    Spacer()
                    Text(push.enabled ? "On" : "Off")
                        .font(Theme.engraved(12))
                        .foregroundStyle(Theme.ash)
                }
            }
            .listRowBackground(Theme.surface)
        } header: {
            sectionHeader("SETTINGS")
        }
    }
}

struct NotificationsView: View {
    @EnvironmentObject private var push: PushManager
    @State private var relay = ""
    @State private var secret = ""
    @State private var loaded = false

    var body: some View {
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("New letters arrive within seconds. A small relay on your NAS keeps watch over each inbox and sends Apple push notifications with your key.")
                        .font(Theme.serifItalic(15))
                        .foregroundStyle(Theme.ash)

                    InscribedField(label: "Relay address", text: $relay, prompt: "http://100.x.y.z:8787", keyboard: .URL)
                    InscribedField(label: "Relay secret", text: $secret, prompt: "RELAY_SECRET from the relay's YAML", secure: true)

                    Text("Crypt sends the relay each account's server and password so it can watch for new mail. Keep the relay on Tailscale only.")
                        .font(Theme.serifItalic(13))
                        .foregroundStyle(Theme.ash.opacity(0.8))

                    if push.enabled {
                        Button {
                            Task {
                                save()
                                await push.sync()
                            }
                        } label: {
                            Text("Save and reconnect")
                        }
                        .buttonStyle(CrimsonButtonStyle())

                        Button {
                            Task { await push.sendTest() }
                        } label: {
                            Text("Send a test notification")
                        }
                        .buttonStyle(CrimsonButtonStyle(filled: false))

                        Button {
                            Task { await push.turnOff() }
                        } label: {
                            Text("Turn off notifications")
                        }
                        .buttonStyle(CrimsonButtonStyle(filled: false))
                    } else {
                        Button {
                            Task {
                                save()
                                await push.turnOn()
                            }
                        } label: {
                            Text("Turn on notifications")
                        }
                        .buttonStyle(CrimsonButtonStyle())
                        .disabled(relay.isEmpty || secret.isEmpty)
                        .opacity(relay.isEmpty || secret.isEmpty ? 0.5 : 1)
                    }

                    if push.busy {
                        ProgressView().tint(Theme.blood).frame(maxWidth: .infinity)
                    }
                    if !push.status.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: push.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .foregroundStyle(push.statusIsError ? Theme.ember : Theme.blood)
                            Text(push.status)
                                .font(Theme.serif(15))
                                .foregroundStyle(Theme.bone)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(push.statusIsError ? Theme.crimson : Theme.line))
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarTitleDisplayMode(.inline)
        .gothicTitle("Notifications")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            relay = push.relayURL
            secret = push.secret
        }
    }

    private func save() {
        push.relayURL = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        push.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
