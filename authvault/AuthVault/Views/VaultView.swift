import SwiftUI
import UIKit

struct VaultView: View {
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var settings: AppSettings
    @State private var showAdd = false
    @State private var showBackup = false
    @State private var search = ""

    private var filtered: [OTPAccount] {
        guard !search.isEmpty else { return vault.accounts }
        return vault.accounts.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if vault.accounts.isEmpty {
                    emptyState
                } else {
                    List {
                        if search.isEmpty {
                            ForEach(vault.accounts) { account in
                                CodeRow(account: account)
                                    .swipeActions { deleteButton(account) }
                            }
                            .onMove { vault.move(from: $0, to: $1) }
                        } else {
                            ForEach(filtered) { account in
                                CodeRow(account: account).swipeActions { deleteButton(account) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
                }
            }
            .navigationTitle("AuthVault")
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton().disabled(vault.accounts.isEmpty) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
                        Button { showBackup = true } label: { Label("Backup & settings", systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showAdd) { AddAccountView().environmentObject(vault) }
            .sheet(isPresented: $showBackup) { BackupView().environmentObject(vault).environmentObject(settings) }
        }
    }

    private func deleteButton(_ account: OTPAccount) -> some View {
        Button(role: .destructive) { vault.delete(account) } label: { Label("Delete", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text("No codes yet").font(.headline)
            Text("Add an account by scanning its QR code, or enter the key by hand.")
                .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).padding(.horizontal, 36)
            Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showAdd) { AddAccountView().environmentObject(vault) }
    }
}

private struct CodeRow: View {
    let account: OTPAccount
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = TOTP.code(account.config, at: context.date)
            let remaining = TOTP.remaining(account.config, at: context.date)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title).font(.subheadline.weight(.semibold))
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Text(copied ? "Copied" : code.groupedCode)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(copied ? Theme.good : Theme.accent)
                        .monospacedDigit()
                        .contentTransition(.identity)
                }
                Spacer()
                CountdownRing(remaining: remaining, period: account.config.period)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                UIPasteboard.general.string = code
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            }
        }
    }
}

private struct CountdownRing: View {
    let remaining: Int
    let period: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surface, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, remaining)) / CGFloat(max(period, 1)))
                .stroke(Theme.countdownColor(remaining, period: period), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: remaining)
            Text("\(remaining)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText)
        }
        .frame(width: 36, height: 36)
    }
}
