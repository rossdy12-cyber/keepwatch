import Foundation

/// Sends one message per connection over SMTP with SSL/TLS (465) or STARTTLS (587).
struct SMTPClient {
    let account: MailAccount
    let password: String

    private struct Reply {
        let code: Int
        let lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    func send(_ message: Data, to recipients: [String]) async throws {
        let stream = StreamConnection(host: account.smtpHost, port: account.smtpPort)
        defer { stream.close() }
        if account.smtpSecurity == .tls { stream.startTLS() }

        try expect(try await readReply(stream), 220)
        var ehlo = try await hello(stream)

        if account.smtpSecurity == .startTLS {
            try await stream.write("STARTTLS\r\n")
            try expect(try await readReply(stream), 220)
            stream.startTLS()
            ehlo = try await hello(stream)
        }

        try await authenticate(stream, ehlo: ehlo)

        try await stream.write("MAIL FROM:<\(account.email)>\r\n")
        try expect(try await readReply(stream), 250)
        for recipient in recipients {
            try await stream.write("RCPT TO:<\(recipient)>\r\n")
            let reply = try await readReply(stream)
            guard reply.code == 250 || reply.code == 251 else {
                throw MailError.server("\(recipient) was refused: \(reply.text)")
            }
        }
        try await stream.write("DATA\r\n")
        try expect(try await readReply(stream), 354)
        try await stream.write(dotStuffed(message))
        try await stream.write(".\r\n")
        try expect(try await readReply(stream), 250)
        try? await stream.write("QUIT\r\n")
    }

    func verify() async throws {
        let stream = StreamConnection(host: account.smtpHost, port: account.smtpPort)
        defer { stream.close() }
        if account.smtpSecurity == .tls { stream.startTLS() }
        try expect(try await readReply(stream), 220)
        var ehlo = try await hello(stream)
        if account.smtpSecurity == .startTLS {
            try await stream.write("STARTTLS\r\n")
            try expect(try await readReply(stream), 220)
            stream.startTLS()
            ehlo = try await hello(stream)
        }
        try await authenticate(stream, ehlo: ehlo)
        try? await stream.write("QUIT\r\n")
    }

    private func hello(_ stream: StreamConnection) async throws -> Reply {
        try await stream.write("EHLO crypt.local\r\n")
        let reply = try await readReply(stream)
        try expect(reply, 250)
        return reply
    }

    private func authenticate(_ stream: StreamConnection, ehlo: Reply) async throws {
        let mechanisms = ehlo.lines
            .first { $0.uppercased().hasPrefix("AUTH") }?
            .uppercased()
            .replacingOccurrences(of: "=", with: " ")
            .split(separator: " ")
            .map(String.init) ?? []
        let user = account.loginName
        if mechanisms.contains("PLAIN") || !mechanisms.contains("LOGIN") {
            let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
            try await stream.write("AUTH PLAIN \(token)\r\n")
            let reply = try await readReply(stream)
            guard reply.code == 235 else { throw MailError.auth(reply.text) }
        } else {
            try await stream.write("AUTH LOGIN\r\n")
            try expect(try await readReply(stream), 334)
            try await stream.write(Data(user.utf8).base64EncodedString() + "\r\n")
            try expect(try await readReply(stream), 334)
            try await stream.write(Data(password.utf8).base64EncodedString() + "\r\n")
            let reply = try await readReply(stream)
            guard reply.code == 235 else { throw MailError.auth(reply.text) }
        }
    }

    private func readReply(_ stream: StreamConnection) async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try await stream.readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.protocolError(line)
            }
            let rest = line.dropFirst(4)
            lines.append(String(rest))
            let isLast = line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " "
            if isLast { return Reply(code: code, lines: lines) }
        }
    }

    private func expect(_ reply: Reply, _ code: Int) throws {
        guard reply.code == code else {
            if reply.code == 535 || reply.code == 534 { throw MailError.auth(reply.text) }
            throw MailError.server("Mail server said: \(reply.code) \(reply.text)")
        }
    }

    private func dotStuffed(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        return Data(text.utf8)
    }
}
