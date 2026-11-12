import SwiftUI

struct MailboxListView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    Section {
                        ForEach(store.mailboxes) { mailbox in
                            Button {
                                Task { await store.select(mailbox) }
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: mailbox.symbol)
                                        .frame(width: 24)
                                        .foregroundStyle(Theme.blood)
                                    Text(mailbox.displayName)
                                        .font(Theme.serif(18, weight: mailbox.path == store.currentMailbox?.path ? .semibold : .regular))
                                        .foregroundStyle(Theme.bone)
                                    Spacer()
                                    if mailbox.path == store.currentMailbox?.path {
                                        Text("✠")
                                            .foregroundStyle(Theme.blood)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(mailbox.path == store.currentMailbox?.path ? Theme.crimson.opacity(0.22) : Color.clear)
                            .listRowSeparatorTint(Theme.line)
                        }
                    } header: {
                        Text("MAILBOXES")
                            .font(Theme.engraved(12))
                            .tracking(2)
                            .foregroundStyle(Theme.ash)
                    }

                    if let account = store.account {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.displayName.isEmpty ? account.email : account.displayName)
                                    .font(Theme.serif(17, weight: .semibold))
                                    .foregroundStyle(Theme.bone)
                                Text(account.email)
                                    .font(Theme.serifItalic(14))
                                    .foregroundStyle(Theme.ash)
                                Text("\(account.imapHost) · \(account.smtpHost)")
                                    .font(Theme.engraved(10))
                                    .foregroundStyle(Theme.ash.opacity(0.7))
                            }
                            .listRowBackground(Theme.surface)
                            Button(role: .destructive) {
                                confirmSignOut = true
                            } label: {
                                Text("Sign out")
                                    .font(Theme.engraved(14))
                                    .foregroundStyle(Theme.ember)
                            }
                            .listRowBackground(Theme.surface)
                        } header: {
                            Text("ACCOUNT")
                                .font(Theme.engraved(12))
                                .tracking(2)
                                .foregroundStyle(Theme.ash)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Mailboxes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.engraved(14))
                }
            }
            .confirmationDialog("Sign out of this account? Your mail stays on the server.", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        dismiss()
                        await store.signOut()
                    }
                }
            }
        }
    }
}
