import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: MailStore
    @State private var path: [MessageSummary] = []
    @State private var showMailboxes = false
    @State private var compose: Draft?
    @State private var query = ""
    @State private var started = false

    private var shown: [MessageSummary] {
        store.searchResults ?? store.messages
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GothicBackground()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(store.currentMailbox?.displayName ?? "Crypt")
                            .font(Theme.gothic(26))
                            .foregroundStyle(Theme.bone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if store.accounts.count > 1, let account = store.account {
                            Text(account.label.uppercased())
                                .font(Theme.engraved(9))
                                .tracking(1.5)
                                .foregroundStyle(Theme.ash)
                                .lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showMailboxes = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Mailboxes")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        compose = store.newDraft()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New message")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search the crypt"))
            .onSubmit(of: .search) {
                Task { await store.search(query) }
            }
            .onChange(of: query) { _, value in
                if value.isEmpty { store.clearSearch() }
            }
            .navigationDestination(for: MessageSummary.self) { summary in
                MessageView(summary: summary, compose: $compose)
            }
            .toolbarBackground(Theme.void, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showMailboxes) {
            MailboxListView()
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.void)
        }
        .sheet(item: $compose) { draft in
            ComposeView(draft: draft)
                .interactiveDismissDisabled()
        }
        .overlay(alignment: .bottom) {
            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.errorMessage)
        .task {
            guard !started else { return }
            started = true
            await store.start()
        }
        .onChange(of: store.currentMailbox?.path) { _, _ in
            path = []
            query = ""
        }
        .onChange(of: store.activeID) { _, _ in
            path = []
            query = ""
        }
        .onChange(of: store.messages) { _, _ in openPending() }
        .onChange(of: store.pendingOpenUID) { _, _ in openPending() }
    }

    private func openPending() {
        guard let uid = store.pendingOpenUID, let summary = store.messages.first(where: { $0.uid == uid }) else { return }
        store.pendingOpenUID = nil
        path = [summary]
    }

    @ViewBuilder
    private var content: some View {
        if shown.isEmpty {
            emptyState
        } else {
            List {
                if store.searchResults != nil {
                    Text("\(shown.count) FOUND")
                        .font(Theme.engraved(11))
                        .tracking(2)
                        .foregroundStyle(Theme.ash)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(shown) { summary in
                    NavigationLink(value: summary) {
                        MessageRow(summary: summary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.line)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await store.delete(summary) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Theme.crimson)
                        Button {
                            Task { await store.toggleFlag(summary) }
                        } label: {
                            Label(summary.isFlagged ? "Unflag" : "Flag", systemImage: summary.isFlagged ? "flag.slash" : "flag")
                        }
                        .tint(Color(red: 0.35, green: 0.12, blue: 0.16))
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await store.setSeen(summary, !summary.isSeen) }
                        } label: {
                            Label(summary.isSeen ? "Unread" : "Read", systemImage: summary.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(Color(red: 0.30, green: 0.22, blue: 0.24))
                    }
                    .onAppear {
                        if summary.uid == shown.last?.uid {
                            Task { await store.loadMore() }
                        }
                    }
                }
                if store.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView().tint(Theme.blood)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 120)
                if store.isLoading || store.isSearching {
                    ProgressView()
                        .tint(Theme.blood)
                        .scaleEffect(1.4)
                    Text(store.isSearching ? "Searching the catacombs…" : "Raising the dead letters…")
                        .font(Theme.serifItalic(17))
                        .foregroundStyle(Theme.ash)
                } else {
                    Text("✠")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.crimson)
                        .shadow(color: Theme.blood, radius: 14)
                    Text(store.searchResults != nil ? "Nothing found" : "The crypt is silent")
                        .font(Theme.gothic(34))
                        .foregroundStyle(Theme.bone)
                    Text(store.searchResults != nil ? "No letters match your search." : "No letters rest here.")
                        .font(Theme.serifItalic(17))
                        .foregroundStyle(Theme.ash)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
    }
}

struct MessageRow: View {
    let summary: MessageSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                Sigil(name: summary.from?.displayName ?? "?", size: 40)
                    .opacity(summary.isSeen ? 0.65 : 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !summary.isSeen {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.blood)
                            .shadow(color: Theme.blood, radius: 4)
                            .accessibilityLabel("Unread")
                    }
                    Text(summary.from?.displayName ?? "Unknown")
                        .font(Theme.serif(17, weight: summary.isSeen ? .regular : .semibold))
                        .foregroundStyle(summary.isSeen ? Theme.bone.opacity(0.75) : Theme.bone)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if summary.isAnswered {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ash)
                    }
                    if summary.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.blood)
                    }
                    Text(summary.date.mailStamp)
                        .font(Theme.engraved(11))
                        .foregroundStyle(summary.isSeen ? Theme.ash : Theme.ember)
                }
                Text(summary.subject.isEmpty ? "(no subject)" : summary.subject)
                    .font(Theme.serif(15, weight: summary.isSeen ? .regular : .semibold))
                    .foregroundStyle(summary.isSeen ? Theme.bone.opacity(0.7) : Theme.bone)
                    .lineLimit(1)
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(Theme.serifItalic(14))
                        .foregroundStyle(Theme.ash)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.ember)
            Text(message)
                .font(Theme.serif(15))
                .foregroundStyle(Theme.bone)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.ash)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.crimson))
        .shadow(color: .black.opacity(0.6), radius: 12)
    }
}
