import Foundation
import SwiftUI
import UserNotifications

struct Draft: Identifiable {
    let id = UUID()
    var accountID: UUID?
    var to: String = ""
    var cc: String = ""
    var subject: String = ""
    var body: String = ""
    var attachments: [Attachment] = []
    var inReplyTo: String?
    var references: String?
    var answeredUID: UInt32?
    var answeredMailbox: String?
}

@MainActor
final class MailStore: ObservableObject {
    static let shared = MailStore()

    @Published private(set) var accounts: [MailAccount] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var unreadCounts: [UUID: Int] = [:]
    @Published private(set) var mailboxes: [Mailbox] = []
    @Published var currentMailbox: Mailbox?
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var searchResults: [MessageSummary]?
    @Published private(set) var isSearching = false
    /// A message to open once the inbox has loaded (from a tapped notification).
    @Published var pendingOpenUID: UInt32?

    private var clients: [UUID: IMAPClient] = [:]
    private var bodyCache: [String: ParsedMessage] = [:]
    private var loadToken = UUID()

    private init() {
        accounts = AccountStorage.loadAll()
        activeID = AccountStorage.activeID.flatMap { id in accounts.contains { $0.id == id } ? id : nil } ?? accounts.first?.id
    }

    var account: MailAccount? { accounts.first { $0.id == activeID } }
    var hasAccounts: Bool { !accounts.isEmpty }

    private func imapClient(for id: UUID?) -> IMAPClient? {
        guard let id else { return nil }
        if let existing = clients[id] { return existing }
        guard let account = accounts.first(where: { $0.id == id }),
              let password = AccountStorage.password(for: id) else { return nil }
        let created = IMAPClient(account: account, password: password)
        clients[id] = created
        return created
    }

    private var client: IMAPClient? { imapClient(for: activeID) }

    var canLoadMore: Bool {
        guard let oldest = messages.last else { return false }
        return oldest.sequence > 1 && searchResults == nil
    }

    var trashMailbox: Mailbox? { mailboxes.first { $0.role == .trash } }
    var archiveMailbox: Mailbox? { mailboxes.first { $0.role == .archive } }
    var sentMailbox: Mailbox? { mailboxes.first { $0.role == .sent } }
    var junkMailbox: Mailbox? { mailboxes.first { $0.role == .junk } }

    // MARK: Accounts

    /// Checks the account can receive and send, then saves it and switches to it.
    func addAccount(_ account: MailAccount, password: String) async throws {
        let imap = IMAPClient(account: account, password: password)
        try await imap.verify()
        try await SMTPClient(account: account, password: password).verify()

        var account = account
        if let existing = accounts.first(where: { $0.email.lowercased() == account.email.lowercased() }) {
            // Signing in again with the same address replaces that account.
            account.id = existing.id
            await clients[existing.id]?.disconnect()
            accounts.removeAll { $0.id == existing.id }
        }
        AccountStorage.setPassword(password, for: account.id)
        accounts.append(account)
        AccountStorage.saveAll(accounts)
        clients[account.id] = imap
        bodyCache = [:]
        activeID = nil
        await switchTo(account.id)
        await PushManager.shared.sync()
    }

    func removeAccount(_ id: UUID) async {
        await clients[id]?.disconnect()
        clients[id] = nil
        accounts.removeAll { $0.id == id }
        unreadCounts[id] = nil
        AccountStorage.saveAll(accounts)
        AccountStorage.deletePassword(for: id)
        bodyCache = bodyCache.filter { !$0.key.hasPrefix(id.uuidString) }
        if activeID == id {
            activeID = nil
            resetMailState()
            if let next = accounts.first {
                await switchTo(next.id)
            } else {
                AccountStorage.activeID = nil
            }
        }
        await PushManager.shared.sync()
        updateBadge()
    }

    func switchTo(_ id: UUID) async {
        guard id != activeID, accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        AccountStorage.activeID = id
        resetMailState()
        await start()
    }

    private func resetMailState() {
        loadToken = UUID()
        mailboxes = []
        messages = []
        total = 0
        currentMailbox = nil
        searchResults = nil
        isLoading = false
    }

    // MARK: Loading

    func start() async {
        guard let client else { return }
        let accountID = activeID
        do {
            let boxes = try await client.mailboxes()
            guard accountID == activeID else { return }
            mailboxes = boxes
            if currentMailbox == nil || !boxes.contains(where: { $0.path == currentMailbox?.path }) {
                currentMailbox = boxes.first { $0.role == .inbox } ?? boxes.first
            }
        } catch {
            guard accountID == activeID else { return }
            report(error)
            if currentMailbox == nil {
                currentMailbox = Mailbox(path: "INBOX", delimiter: "/", attributes: [])
            }
        }
        await refresh()
    }

    func select(_ mailbox: Mailbox) async {
        guard mailbox.path != currentMailbox?.path else { return }
        currentMailbox = mailbox
        messages = []
        total = 0
        searchResults = nil
        await refresh()
    }

    func refresh() async {
        guard let client, let mailbox = currentMailbox else { return }
        let token = UUID()
        loadToken = token
        isLoading = true
        defer { if loadToken == token { isLoading = false } }
        Task { await refreshUnreadCounts() }
        do {
            let result = try await client.messages(in: mailbox.path, beforeSequence: nil)
            guard loadToken == token else { return }
            total = result.total
            messages = result.messages
            errorMessage = nil
        } catch {
            if loadToken == token { report(error) }
        }
    }

    /// Inbox unread counts for every account, for the account list and the app badge.
    func refreshUnreadCounts() async {
        await withTaskGroup(of: (UUID, Int?).self) { group in
            for account in accounts {
                guard let imap = imapClient(for: account.id) else { continue }
                let id = account.id
                group.addTask {
                    (id, try? await imap.unseenCount())
                }
            }
            for await (id, count) in group {
                if let count { unreadCounts[id] = count }
            }
        }
        updateBadge()
    }

    private func updateBadge() {
        let total = accounts.reduce(0) { $0 + (unreadCounts[$1.id] ?? 0) }
        UNUserNotificationCenter.current().setBadgeCount(total) { _ in }
    }

    func loadMore() async {
        guard let client, let mailbox = currentMailbox, let oldest = messages.last, !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.messages(in: mailbox.path, beforeSequence: oldest.sequence)
            let known = Set(messages.map(\.uid))
            messages += result.messages.filter { !known.contains($0.uid) }
        } catch {
            report(error)
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let client, let mailbox = currentMailbox, !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.search(trimmed, in: mailbox.path)
        } catch {
            report(error)
        }
    }

    func clearSearch() {
        searchResults = nil
    }

    func message(for summary: MessageSummary) async throws -> ParsedMessage {
        guard let client, let mailbox = currentMailbox, let activeID else { throw MailError.notConfigured }
        let key = "\(activeID.uuidString)|\(mailbox.path)|\(summary.uid)"
        if let cached = bodyCache[key] { return cached }
        let data = try await client.body(uid: summary.uid, in: mailbox.path)
        let parsed = await Task.detached(priority: .userInitiated) { MIME.parse(data) }.value
        bodyCache[key] = parsed
        return parsed
    }

    /// Opens the account (and message) a tapped notification is about.
    func openFromNotification(accountID: UUID, uid: UInt32?) async {
        guard accounts.contains(where: { $0.id == accountID }) else { return }
        pendingOpenUID = uid
        if accountID != activeID {
            await switchTo(accountID)
        } else if currentMailbox?.role != .inbox, let inbox = mailboxes.first(where: { $0.role == .inbox }) {
            await select(inbox)
        } else {
            await refresh()
        }
    }

    // MARK: Actions

    private func update(_ uid: UInt32, _ change: (inout MessageSummary) -> Void) {
        if let index = messages.firstIndex(where: { $0.uid == uid }) {
            change(&messages[index])
        }
        if var results = searchResults, let index = results.firstIndex(where: { $0.uid == uid }) {
            change(&results[index])
            searchResults = results
        }
    }

    private func remove(_ uid: UInt32) {
        messages.removeAll { $0.uid == uid }
        searchResults?.removeAll { $0.uid == uid }
    }

    private func adjustUnread(by delta: Int) {
        guard let activeID, currentMailbox?.role == .inbox else { return }
        unreadCounts[activeID] = max(0, (unreadCounts[activeID] ?? 0) + delta)
        updateBadge()
    }

    func setSeen(_ summary: MessageSummary, _ seen: Bool) async {
        guard let client, let mailbox = currentMailbox, summary.isSeen != seen else { return }
        update(summary.uid) { if seen { $0.flags.insert("\\Seen") } else { $0.flags.remove("\\Seen") } }
        adjustUnread(by: seen ? -1 : 1)
        do {
            try await client.setFlag("\\Seen", on: seen, uid: summary.uid, in: mailbox.path)
        } catch {
            update(summary.uid) { if seen { $0.flags.remove("\\Seen") } else { $0.flags.insert("\\Seen") } }
            adjustUnread(by: seen ? 1 : -1)
            report(error)
        }
    }

    func toggleFlag(_ summary: MessageSummary) async {
        guard let client, let mailbox = currentMailbox else { return }
        let flagged = !summary.isFlagged
        update(summary.uid) { if flagged { $0.flags.insert("\\Flagged") } else { $0.flags.remove("\\Flagged") } }
        do {
            try await client.setFlag("\\Flagged", on: flagged, uid: summary.uid, in: mailbox.path)
        } catch {
            update(summary.uid) { if flagged { $0.flags.remove("\\Flagged") } else { $0.flags.insert("\\Flagged") } }
            report(error)
        }
    }

    func delete(_ summary: MessageSummary) async {
        guard let client, let mailbox = currentMailbox else { return }
        remove(summary.uid)
        if !summary.isSeen { adjustUnread(by: -1) }
        do {
            if let trash = trashMailbox, trash.path != mailbox.path {
                try await client.move(uid: summary.uid, from: mailbox.path, to: trash.path)
            } else {
                try await client.deletePermanently(uid: summary.uid, in: mailbox.path)
            }
            total = max(0, total - 1)
        } catch {
            report(error)
            await refresh()
        }
    }

    func move(_ summary: MessageSummary, to destination: Mailbox) async {
        guard let client, let mailbox = currentMailbox, destination.path != mailbox.path else { return }
        remove(summary.uid)
        if !summary.isSeen { adjustUnread(by: -1) }
        do {
            try await client.move(uid: summary.uid, from: mailbox.path, to: destination.path)
            total = max(0, total - 1)
        } catch {
            report(error)
            await refresh()
        }
    }

    func send(_ draft: Draft) async throws {
        let accountID = draft.accountID ?? activeID
        guard let account = accounts.first(where: { $0.id == accountID }),
              let password = AccountStorage.password(for: account.id),
              let client = imapClient(for: account.id) else { throw MailError.notConfigured }
        let to = EmailAddress.parseList(draft.to)
        let cc = EmailAddress.parseList(draft.cc)
        guard !to.isEmpty || !cc.isEmpty else { throw MailError.server("Add at least one recipient.") }
        for address in to + cc where !address.address.contains("@") {
            throw MailError.server("“\(address.address)” isn't an email address.")
        }
        let built = MIME.buildMessage(
            from: account.sender,
            to: to,
            cc: cc,
            subject: draft.subject,
            body: draft.body,
            attachments: draft.attachments,
            inReplyTo: draft.inReplyTo,
            references: draft.references
        )
        try await SMTPClient(account: account, password: password)
            .send(built.data, to: (to + cc).map(\.address))

        if account.saveSentCopy {
            let sentPath: String?
            if account.id == activeID {
                sentPath = sentMailbox?.path
            } else {
                sentPath = (try? await client.mailboxes())?.first { $0.role == .sent }?.path
            }
            if let sentPath {
                try? await client.append(built.data, to: sentPath)
            }
        }
        if let uid = draft.answeredUID, let mailbox = draft.answeredMailbox {
            try? await client.setFlag("\\Answered", on: true, uid: uid, in: mailbox)
            if account.id == activeID, mailbox == currentMailbox?.path {
                update(uid) { $0.flags.insert("\\Answered") }
            }
        }
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorMessage = error.localizedDescription
    }

    // MARK: Drafts for replies

    func newDraft() -> Draft {
        var draft = Draft()
        draft.accountID = activeID
        return draft
    }

    func replyDraft(to summary: MessageSummary, message: ParsedMessage, all: Bool) -> Draft {
        var draft = newDraft()
        let sender = message.replyTo.first ?? message.from.first
        var recipients = [sender].compactMap { $0 }
        var ccList: [EmailAddress] = []
        if all {
            let me = account?.email.lowercased() ?? ""
            let others = (message.to + message.cc).filter {
                $0.address.lowercased() != me && $0.address.lowercased() != sender?.address.lowercased()
            }
            if recipients.isEmpty {
                recipients = others
            } else {
                ccList = others
            }
        }
        draft.to = recipients.map(\.headerValueForEditing).joined(separator: ", ")
        draft.cc = ccList.map(\.headerValueForEditing).joined(separator: ", ")
        let subject = message.subject
        draft.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        draft.inReplyTo = message.messageID
        draft.references = message.references
        draft.answeredUID = summary.uid
        draft.answeredMailbox = currentMailbox?.path
        draft.body = "\n\n" + quoteHeader(message) + "\n" + quoted(message.bodyText)
        return draft
    }

    func forwardDraft(message: ParsedMessage) -> Draft {
        var draft = newDraft()
        let subject = message.subject
        draft.subject = subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
        var header = "\n\n——— Forwarded message ———\n"
        header += "From: \(message.from.map(\.headerValueForEditing).joined(separator: ", "))\n"
        if let date = message.date {
            header += "Date: \(date.formatted(date: .long, time: .shortened))\n"
        }
        header += "Subject: \(subject)\n"
        header += "To: \(message.to.map(\.headerValueForEditing).joined(separator: ", "))\n\n"
        draft.body = header + message.bodyText
        draft.attachments = message.attachments
        return draft
    }

    private func quoteHeader(_ message: ParsedMessage) -> String {
        let who = message.from.first?.displayName ?? "someone"
        if let date = message.date {
            return "On \(date.formatted(date: .abbreviated, time: .shortened)), \(who) wrote:"
        }
        return "\(who) wrote:"
    }

    private func quoted(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
    }
}

extension EmailAddress {
    /// A friendly form for the compose fields: `Name <address>`.
    var headerValueForEditing: String {
        guard !name.isEmpty else { return address }
        if name.contains(",") || name.contains(";") {
            return "\"\(name.replacingOccurrences(of: "\"", with: ""))\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }
}
