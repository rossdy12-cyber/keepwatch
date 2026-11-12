import Foundation
import SwiftUI

struct Draft: Identifiable {
    let id = UUID()
    var to: String = ""
    var cc: String = ""
    var subject: String = ""
    var body: String = ""
    var inReplyTo: String?
    var references: String?
    var answeredUID: UInt32?
    var answeredMailbox: String?
}

@MainActor
final class MailStore: ObservableObject {
    @Published private(set) var account: MailAccount?
    @Published private(set) var mailboxes: [Mailbox] = []
    @Published var currentMailbox: Mailbox?
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var searchResults: [MessageSummary]?
    @Published private(set) var isSearching = false

    private var client: IMAPClient?
    private var password: String?
    private var bodyCache: [String: ParsedMessage] = [:]
    private var loadToken = UUID()

    init() {
        if let account = AccountStorage.load(), let password = AccountStorage.password() {
            self.account = account
            self.password = password
            client = IMAPClient(account: account, password: password)
        }
    }

    var canLoadMore: Bool {
        guard let oldest = messages.last else { return false }
        return oldest.sequence > 1 && searchResults == nil
    }

    var trashMailbox: Mailbox? { mailboxes.first { $0.role == .trash } }
    var archiveMailbox: Mailbox? { mailboxes.first { $0.role == .archive } }
    var sentMailbox: Mailbox? { mailboxes.first { $0.role == .sent } }
    var junkMailbox: Mailbox? { mailboxes.first { $0.role == .junk } }

    // MARK: Account

    func signIn(account: MailAccount, password: String) async throws {
        let imap = IMAPClient(account: account, password: password)
        try await imap.verify()
        try await SMTPClient(account: account, password: password).verify()
        AccountStorage.save(account, password: password)
        await client?.disconnect()
        self.account = account
        self.password = password
        client = imap
        bodyCache = [:]
        mailboxes = []
        messages = []
        currentMailbox = nil
        await start()
    }

    func signOut() async {
        await client?.disconnect()
        AccountStorage.clear()
        client = nil
        account = nil
        password = nil
        mailboxes = []
        messages = []
        currentMailbox = nil
        bodyCache = [:]
        searchResults = nil
    }

    // MARK: Loading

    func start() async {
        guard let client else { return }
        do {
            let boxes = try await client.mailboxes()
            mailboxes = boxes
            if currentMailbox == nil || !boxes.contains(where: { $0.path == currentMailbox?.path }) {
                currentMailbox = boxes.first { $0.role == .inbox } ?? boxes.first
            }
        } catch {
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
        guard let client, let mailbox = currentMailbox else { throw MailError.notConfigured }
        let key = "\(mailbox.path)|\(summary.uid)"
        if let cached = bodyCache[key] { return cached }
        let data = try await client.body(uid: summary.uid, in: mailbox.path)
        let parsed = await Task.detached(priority: .userInitiated) { MIME.parse(data) }.value
        bodyCache[key] = parsed
        return parsed
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

    func setSeen(_ summary: MessageSummary, _ seen: Bool) async {
        guard let client, let mailbox = currentMailbox, summary.isSeen != seen else { return }
        update(summary.uid) { if seen { $0.flags.insert("\\Seen") } else { $0.flags.remove("\\Seen") } }
        do {
            try await client.setFlag("\\Seen", on: seen, uid: summary.uid, in: mailbox.path)
        } catch {
            update(summary.uid) { if seen { $0.flags.remove("\\Seen") } else { $0.flags.insert("\\Seen") } }
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
        do {
            try await client.move(uid: summary.uid, from: mailbox.path, to: destination.path)
            total = max(0, total - 1)
        } catch {
            report(error)
            await refresh()
        }
    }

    func send(_ draft: Draft) async throws {
        guard let account, let password, let client else { throw MailError.notConfigured }
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
            inReplyTo: draft.inReplyTo,
            references: draft.references
        )
        try await SMTPClient(account: account, password: password)
            .send(built.data, to: (to + cc).map(\.address))

        if account.saveSentCopy, let sent = sentMailbox {
            try? await client.append(built.data, to: sent.path)
        }
        if let uid = draft.answeredUID, let mailbox = draft.answeredMailbox {
            try? await client.setFlag("\\Answered", on: true, uid: uid, in: mailbox)
            if mailbox == currentMailbox?.path {
                update(uid) { $0.flags.insert("\\Answered") }
            }
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        errorMessage = error.localizedDescription
    }

    // MARK: Drafts for replies

    func replyDraft(to summary: MessageSummary, message: ParsedMessage, all: Bool) -> Draft {
        var draft = Draft()
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
        var draft = Draft()
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
