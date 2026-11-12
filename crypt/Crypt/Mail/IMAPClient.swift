import Foundation

enum MailboxRole: Int, Comparable {
    case inbox = 0, flagged, drafts, sent, archive, junk, trash, all, other

    static func < (lhs: MailboxRole, rhs: MailboxRole) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Mailbox: Identifiable, Hashable {
    var id: String { path }
    let path: String          // raw name used in commands
    let delimiter: String
    let attributes: [String]

    var role: MailboxRole {
        let attrs = Set(attributes.map { $0.lowercased() })
        if path.uppercased() == "INBOX" { return .inbox }
        if attrs.contains("\\sent") { return .sent }
        if attrs.contains("\\trash") { return .trash }
        if attrs.contains("\\drafts") { return .drafts }
        if attrs.contains("\\junk") { return .junk }
        if attrs.contains("\\archive") { return .archive }
        if attrs.contains("\\flagged") { return .flagged }
        if attrs.contains("\\all") { return .all }
        let leaf = displayLeaf.lowercased()
        switch leaf {
        case "sent", "sent messages", "sent items", "sent mail": return .sent
        case "trash", "deleted messages", "deleted items", "bin": return .trash
        case "drafts": return .drafts
        case "junk", "spam", "bulk mail": return .junk
        case "archive": return .archive
        default: return .other
        }
    }

    var displayLeaf: String {
        let decoded = ModifiedUTF7.decode(path)
        guard !delimiter.isEmpty else { return decoded }
        return decoded.components(separatedBy: delimiter).last ?? decoded
    }

    var displayName: String {
        switch role {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .trash: return "Trash"
        case .drafts: return "Drafts"
        case .junk: return "Junk"
        case .archive: return "Archive"
        case .flagged: return "Flagged"
        case .all: return "All Mail"
        case .other:
            let decoded = ModifiedUTF7.decode(path)
            guard !delimiter.isEmpty else { return decoded }
            return decoded.components(separatedBy: delimiter).joined(separator: " / ")
        }
    }

    var symbol: String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .trash: return "trash"
        case .drafts: return "doc.text"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .flagged: return "flag"
        case .all: return "tray.2"
        case .other: return "folder"
        }
    }

    var isSelectable: Bool {
        !attributes.contains { $0.lowercased() == "\\noselect" || $0.lowercased() == "\\nonexistent" }
    }
}

struct MessageSummary: Identifiable, Hashable {
    var id: UInt32 { uid }
    let uid: UInt32
    let sequence: Int
    var flags: Set<String>
    let from: EmailAddress?
    let to: [EmailAddress]
    let subject: String
    let date: Date
    let preview: String
    let messageID: String?

    var isSeen: Bool { flags.contains("\\Seen") }
    var isFlagged: Bool { flags.contains("\\Flagged") }
    var isAnswered: Bool { flags.contains("\\Answered") }
}

/// A single IMAP connection over implicit TLS.
final class IMAPConnection {
    private let stream: StreamConnection
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    var selected: String?

    init(host: String, port: Int) {
        stream = StreamConnection(host: host, port: port)
        stream.startTLS()
    }

    func close() {
        stream.close()
    }

    func readGreeting() async throws {
        let line = try await stream.readLine()
        guard line.hasPrefix("* OK") || line.hasPrefix("* PREAUTH") else {
            throw MailError.protocolError(line)
        }
        noteCapabilities(in: line)
    }

    private func noteCapabilities(in line: String) {
        guard let range = line.range(of: "CAPABILITY ", options: .caseInsensitive) else { return }
        var rest = String(line[range.upperBound...])
        if let close = rest.firstIndex(of: "]") { rest = String(rest[..<close]) }
        capabilities.formUnion(rest.uppercased().split(separator: " ").map(String.init))
    }

    /// Reads one full response, including any literals it carries.
    private func readResponse() async throws -> Data {
        var out = Data()
        while true {
            let line = try await stream.readLineData()
            out.append(line)
            if let count = Self.trailingLiteralLength(line) {
                out.append(contentsOf: [13, 10])
                out.append(try await stream.readBytes(count))
                continue
            }
            return out
        }
    }

    private static func trailingLiteralLength(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.endIndex - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Runs a command. Extra segments are sent one by one after each `+` continuation
    /// request (used for literals and for SASL).
    @discardableResult
    func execute(_ command: String, continuations: [Data] = []) async throws -> [Data] {
        tagCounter += 1
        let tag = String(format: "C%04d", tagCounter)
        try await stream.write("\(tag) \(command)\r\n")
        var pending = continuations
        var untagged: [Data] = []
        while true {
            let response = try await readResponse()
            if response.starts(with: Data("+".utf8)) {
                if pending.isEmpty {
                    // Unexpected continuation: cancel it.
                    try await stream.write("*\r\n")
                } else {
                    var chunk = pending.removeFirst()
                    chunk.append(contentsOf: [13, 10])
                    try await stream.write(chunk)
                }
                continue
            }
            if response.starts(with: Data("\(tag) ".utf8)) {
                let text = String(decoding: response.dropFirst(tag.count + 1), as: UTF8.self)
                noteCapabilities(in: text)
                if text.uppercased().hasPrefix("OK") { return untagged }
                let message = text.count > 3 ? String(text.dropFirst(3)) : text
                throw MailError.server(Self.cleanServerText(message))
            }
            if response.starts(with: Data("* CAPABILITY".utf8)) {
                noteCapabilities(in: String(decoding: response, as: UTF8.self))
            }
            if response.starts(with: Data("* BYE".utf8)), !command.uppercased().hasPrefix("LOGOUT") {
                throw MailError.connectionClosed
            }
            untagged.append(response)
        }
    }

    private static func cleanServerText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("["), let close = cleaned.firstIndex(of: "]") {
            cleaned = String(cleaned[cleaned.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? "The server refused the request." : cleaned
    }

    func login(user: String, password: String) async throws {
        let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedData()
        do {
            try await execute("AUTHENTICATE PLAIN", continuations: [token])
        } catch MailError.server(let text) {
            // Fall back to LOGIN for servers without SASL PLAIN.
            if capabilities.contains("AUTH=PLAIN") || password.unicodeScalars.contains(where: { !$0.isASCII }) {
                throw MailError.auth(text)
            }
            do {
                try await execute("LOGIN \(Self.quote(user)) \(Self.quote(password))")
            } catch MailError.server(let text) {
                throw MailError.auth(text)
            }
        }
        if capabilities.count < 3 || !capabilities.contains("IMAP4REV1") {
            try? await execute("CAPABILITY")
        }
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// High-level IMAP operations. Keeps one connection open and reconnects when it drops.
actor IMAPClient {
    private let account: MailAccount
    private let password: String
    private var connection: IMAPConnection?

    init(account: MailAccount, password: String) {
        self.account = account
        self.password = password
    }

    func disconnect() async {
        if let connection {
            _ = try? await connection.execute("LOGOUT")
            connection.close()
        }
        connection = nil
    }

    private func connect() async throws -> IMAPConnection {
        if let connection { return connection }
        let conn = IMAPConnection(host: account.imapHost, port: account.imapPort)
        do {
            try await conn.readGreeting()
            try await conn.login(user: account.loginName, password: password)
        } catch {
            conn.close()
            throw error
        }
        connection = conn
        return conn
    }

    private func run<T>(_ body: (IMAPConnection) async throws -> T) async throws -> T {
        do {
            return try await body(try await connect())
        } catch let error as MailError {
            switch error {
            case .connectionClosed, .timeout:
                connection?.close()
                connection = nil
                return try await body(try await connect())
            default:
                throw error
            }
        } catch {
            // Network-level failure: try once more on a fresh connection.
            connection?.close()
            connection = nil
            return try await body(try await connect())
        }
    }

    func verify() async throws {
        try await run { _ in }
    }

    func mailboxes() async throws -> [Mailbox] {
        try await run { conn in
            let responses = try await conn.execute("LIST \"\" \"*\"")
            var boxes: [Mailbox] = []
            for response in responses where response.starts(with: Data("* LIST".utf8)) {
                let values = IMAPParser.parse(response)
                // * LIST (attrs) "delim" name
                guard values.count >= 5 else { continue }
                let attrs = values[2].list?.compactMap(\.text) ?? []
                let delimiter = values[3].text ?? ""
                guard let name = values[4].text else { continue }
                boxes.append(Mailbox(path: name, delimiter: delimiter, attributes: attrs))
            }
            return boxes
                .filter(\.isSelectable)
                .sorted { a, b in
                    if a.role != b.role { return a.role < b.role }
                    return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                }
        }
    }

    @discardableResult
    private func select(_ mailbox: String, on conn: IMAPConnection, force: Bool = false) async throws -> Int {
        let responses = try await conn.execute("SELECT \(IMAPConnection.quote(mailbox))")
        conn.selected = mailbox
        for response in responses {
            let text = String(decoding: response, as: UTF8.self)
            let parts = text.split(separator: " ")
            if parts.count >= 3, parts[2].uppercased() == "EXISTS", let count = Int(parts[1]) {
                return count
            }
        }
        return 0
    }

    private func ensureSelected(_ mailbox: String, on conn: IMAPConnection) async throws {
        if conn.selected != mailbox {
            try await select(mailbox, on: conn)
        }
    }

    private static let summaryItems = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.2500>)"

    /// Loads up to `count` messages, newest first, ending just before `beforeSequence`
    /// (or at the newest message). Returns the mailbox's total message count too.
    func messages(in mailbox: String, beforeSequence: Int?, count: Int = 40) async throws -> (total: Int, messages: [MessageSummary]) {
        try await run { conn in
            let total = try await select(mailbox, on: conn)
            let upper = min(total, (beforeSequence ?? (total + 1)) - 1)
            guard upper >= 1 else { return (total, []) }
            let lower = max(1, upper - count + 1)
            let responses = try await conn.execute("FETCH \(lower):\(upper) \(Self.summaryItems)")
            let summaries = responses.compactMap(Self.parseSummary)
            return (total, summaries.sorted { $0.sequence > $1.sequence })
        }
    }

    func search(_ query: String, in mailbox: String) async throws -> [MessageSummary] {
        try await run { conn in
            try await select(mailbox, on: conn)
            let term = Data(query.utf8)
            let responses: [Data]
            if query.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\\" }) {
                responses = try await conn.execute("UID SEARCH TEXT \(IMAPConnection.quote(query))")
            } else {
                responses = try await conn.execute("UID SEARCH CHARSET UTF-8 TEXT {\(term.count)}", continuations: [term])
            }
            var uids: [UInt32] = []
            for response in responses where response.starts(with: Data("* SEARCH".utf8)) {
                let text = String(decoding: response, as: UTF8.self)
                uids += text.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
            }
            let recent = uids.sorted().suffix(60)
            guard !recent.isEmpty else { return [] }
            let set = recent.map(String.init).joined(separator: ",")
            let fetched = try await conn.execute("UID FETCH \(set) \(Self.summaryItems)")
            return fetched.compactMap(Self.parseSummary).sorted { $0.date > $1.date }
        }
    }

    func body(uid: UInt32, in mailbox: String) async throws -> Data {
        try await run { conn in
            try await ensureSelected(mailbox, on: conn)
            let responses = try await conn.execute("UID FETCH \(uid) BODY.PEEK[]")
            for response in responses {
                let values = IMAPParser.parse(response)
                guard let items = values.last?.list else { continue }
                var i = 0
                while i + 1 < items.count {
                    if let key = items[i].text?.uppercased(), key.hasPrefix("BODY[]"), let data = items[i + 1].data {
                        return data
                    }
                    i += 2
                }
            }
            throw MailError.server("That message is no longer on the server.")
        }
    }

    func setFlag(_ flag: String, on: Bool, uid: UInt32, in mailbox: String) async throws {
        try await run { conn in
            try await ensureSelected(mailbox, on: conn)
            try await conn.execute("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
        }
    }

    func move(uid: UInt32, from mailbox: String, to destination: String) async throws {
        try await run { conn in
            try await ensureSelected(mailbox, on: conn)
            if conn.capabilities.contains("MOVE") {
                try await conn.execute("UID MOVE \(uid) \(IMAPConnection.quote(destination))")
            } else {
                try await conn.execute("UID COPY \(uid) \(IMAPConnection.quote(destination))")
                try await conn.execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
                if conn.capabilities.contains("UIDPLUS") {
                    try await conn.execute("UID EXPUNGE \(uid)")
                } else {
                    try await conn.execute("EXPUNGE")
                }
            }
        }
    }

    func deletePermanently(uid: UInt32, in mailbox: String) async throws {
        try await run { conn in
            try await ensureSelected(mailbox, on: conn)
            try await conn.execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            if conn.capabilities.contains("UIDPLUS") {
                try await conn.execute("UID EXPUNGE \(uid)")
            } else {
                try await conn.execute("EXPUNGE")
            }
        }
    }

    func append(_ message: Data, to mailbox: String, flags: String = "(\\Seen)") async throws {
        try await run { conn in
            try await conn.execute("APPEND \(IMAPConnection.quote(mailbox)) \(flags) {\(message.count)}", continuations: [message])
        }
    }

    // MARK: Parsing

    private static func parseSummary(_ response: Data) -> MessageSummary? {
        let values = IMAPParser.parse(response)
        // * <seq> FETCH (...)
        guard values.count >= 4, values[2].text?.uppercased() == "FETCH",
              let sequence = Int(values[1].text ?? ""), let items = values[3].list else { return nil }
        var uid: UInt32?
        var flags: Set<String> = []
        var internalDate: Date?
        var headerData = Data()
        var textData = Data()
        var i = 0
        while i + 1 < items.count {
            let key = items[i].text?.uppercased() ?? ""
            let value = items[i + 1]
            if key == "UID" {
                uid = UInt32(value.text ?? "")
            } else if key == "FLAGS" {
                flags = Set(value.list?.compactMap(\.text) ?? [])
            } else if key == "INTERNALDATE" {
                internalDate = value.text.flatMap(MIME.parseDate)
            } else if key.hasPrefix("BODY[HEADER") {
                headerData = value.data ?? Data()
            } else if key.hasPrefix("BODY[TEXT]") {
                textData = value.data ?? Data()
            }
            i += 2
        }
        guard let uid else { return nil }
        let headers = MIME.parseHeaderBlock(headerData)
        var partial = headerData
        partial.append(contentsOf: [13, 10])
        partial.append(textData)
        let parsed = MIME.parse(partial)
        let previewSource = parsed.plainText ?? parsed.html.map(MIME.htmlToText) ?? ""
        return MessageSummary(
            uid: uid,
            sequence: sequence,
            flags: flags,
            from: EmailAddress.parseList(headers.decoded("From") ?? "").first,
            to: EmailAddress.parseList(headers.decoded("To") ?? ""),
            subject: headers.decoded("Subject") ?? "",
            date: headers.value("Date").flatMap(MIME.parseDate) ?? internalDate ?? .distantPast,
            preview: MIME.preview(from: previewSource),
            messageID: headers.value("Message-ID")
        )
    }
}
