import SwiftUI
import WebKit

struct MessageView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let summary: MessageSummary
    @Binding var compose: Draft?

    @State private var message: ParsedMessage?
    @State private var error: String?
    @State private var showOriginal = false
    @State private var showDetails = false
    @State private var confirmDelete = false

    private var current: MessageSummary {
        (store.searchResults ?? store.messages).first { $0.uid == summary.uid } ?? summary
    }

    var body: some View {
        ZStack {
            GothicBackground()
            VStack(spacing: 0) {
                header
                if let message {
                    if !message.attachments.isEmpty {
                        attachments(message.attachments)
                    }
                    MessageBodyView(html: bodyHTML(message))
                } else if let error {
                    Spacer()
                    VStack(spacing: 12) {
                        Text("✠").font(.system(size: 30)).foregroundStyle(Theme.crimson)
                        Text(error)
                            .font(Theme.serif(16))
                            .foregroundStyle(Theme.ash)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }
                            .font(Theme.engraved(14))
                    }
                    .padding()
                    Spacer()
                } else {
                    Spacer()
                    ProgressView().tint(Theme.blood).scaleEffect(1.3)
                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if message?.html != nil {
                    Button {
                        showOriginal.toggle()
                    } label: {
                        Image(systemName: showOriginal ? "moon.fill" : "sun.max")
                    }
                    .accessibilityLabel(showOriginal ? "Show in Crypt colours" : "Show original colours")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
                Spacer()
                Button {
                    Task { await store.toggleFlag(current) }
                } label: {
                    Image(systemName: current.isFlagged ? "flag.fill" : "flag")
                }
                .accessibilityLabel(current.isFlagged ? "Unflag" : "Flag")
                Spacer()
                moveMenu
                Spacer()
                Button {
                    Task {
                        await store.setSeen(current, false)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "envelope.badge")
                }
                .accessibilityLabel("Mark as unread")
                Spacer()
                replyMenu
            }
        }
        .toolbarBackground(Theme.void, for: .bottomBar)
        .toolbarBackground(.visible, for: .bottomBar)
        .confirmationDialog("Delete this letter?", isPresented: $confirmDelete) {
            Button(store.currentMailbox?.role == .trash ? "Delete forever" : "Move to Trash", role: .destructive) {
                Task {
                    await store.delete(current)
                    dismiss()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            message = try await store.message(for: summary)
            await store.setSeen(current, true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.subject.isEmpty ? "(no subject)" : current.subject)
                .font(Theme.serif(23, weight: .semibold))
                .foregroundStyle(Theme.bone)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 12) {
                Sigil(name: current.from?.displayName ?? "?", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.from?.displayName ?? "Unknown")
                        .font(Theme.serif(17, weight: .semibold))
                        .foregroundStyle(Theme.bone)
                    if let address = current.from?.address, current.from?.name.isEmpty == false {
                        Text(address)
                            .font(Theme.serifItalic(14))
                            .foregroundStyle(Theme.ash)
                            .textSelection(.enabled)
                    }
                    Button {
                        withAnimation { showDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(recipientLine)
                                .lineLimit(showDetails ? nil : 1)
                                .multilineTextAlignment(.leading)
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .font(Theme.serif(13))
                        .foregroundStyle(Theme.ash)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text(current.date == .distantPast ? "" : current.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.engraved(10))
                    .foregroundStyle(Theme.ember)
                    .multilineTextAlignment(.trailing)
            }
            OrnamentDivider()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var recipientLine: String {
        let to = (message?.to ?? current.to).map(\.displayName)
        let cc = (message?.cc ?? []).map(\.displayName)
        var line = "to " + (to.isEmpty ? "undisclosed" : to.joined(separator: ", "))
        if showDetails, !cc.isEmpty { line += "\ncc " + cc.joined(separator: ", ") }
        if showDetails, let from = current.from?.address { line += "\nfrom \(from)" }
        return line
    }

    private func attachments(_ items: [Attachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    if let url = AttachmentFiles.url(for: item) {
                        ShareLink(item: url) {
                            attachmentChip(item)
                        }
                    } else {
                        attachmentChip(item)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    private func attachmentChip(_ item: Attachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
            Text(item.filename).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                .foregroundStyle(Theme.ash)
        }
        .font(Theme.serif(13))
        .foregroundStyle(Theme.bone)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.crimson))
    }

    // MARK: Menus

    private var replyMenu: some View {
        Menu {
            Button {
                if let message { compose = store.replyDraft(to: current, message: message, all: false) }
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button {
                if let message { compose = store.replyDraft(to: current, message: message, all: true) }
            } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
            Button {
                if let message { compose = store.forwardDraft(message: message) }
            } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
        }
        .disabled(message == nil)
        .accessibilityLabel("Reply")
    }

    private var moveMenu: some View {
        Menu {
            if let archive = store.archiveMailbox, archive.path != store.currentMailbox?.path {
                Button {
                    Task { await store.move(current, to: archive); dismiss() }
                } label: { Label("Archive", systemImage: "archivebox") }
            }
            if let junk = store.junkMailbox, junk.path != store.currentMailbox?.path {
                Button {
                    Task { await store.move(current, to: junk); dismiss() }
                } label: { Label("Junk", systemImage: "xmark.bin") }
            }
            Section("Move to") {
                ForEach(store.mailboxes.filter { $0.path != store.currentMailbox?.path && $0.role != .all && $0.role != .flagged }) { box in
                    Button {
                        Task { await store.move(current, to: box); dismiss() }
                    } label: { Label(box.displayName, systemImage: box.symbol) }
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .accessibilityLabel("Move")
    }

    // MARK: Body HTML

    private func bodyHTML(_ message: ParsedMessage) -> String {
        if let html = message.html {
            return HTMLTemplate.wrapHTML(html, gothic: !showOriginal)
        }
        return HTMLTemplate.wrapPlain(message.plainText ?? "")
    }
}

enum AttachmentFiles {
    static func url(for attachment: Attachment) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments/\(attachment.id.uuidString)", isDirectory: true)
        let safeName = attachment.filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try attachment.data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

enum HTMLTemplate {
    private static let fonts = """
    @font-face { font-family: 'Unifraktur'; src: local('UnifrakturMaguntia'); }
    """

    private static let gothicCSS = """
    :root { color-scheme: dark; }
    html, body { background: #090507 !important; margin: 0; padding: 0; }
    body { color: #EADFD0; font: 17px/1.55 Baskerville, Georgia, serif; padding: 6px 18px 40px; -webkit-text-size-adjust: 100%; word-wrap: break-word; }
    a { color: #E65261; }
    pre.plain { white-space: pre-wrap; font: inherit; margin: 0; }
    blockquote, .quote { border-left: 2px solid #8B0A1A; margin: 8px 0; padding-left: 12px; color: #9E8C87; }
    img { max-width: 100%; height: auto; }
    ::selection { background: #8B0A1A; }
    """

    static func wrapPlain(_ text: String) -> String {
        var html = ""
        var inQuote = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let isQuote = line.hasPrefix(">")
            if isQuote != inQuote {
                html += isQuote ? "<div class=\"quote\">" : "</div>"
                inQuote = isQuote
            }
            let content = isQuote ? String(line.drop(while: { $0 == ">" || $0 == " " })) : line
            html += linkify(escape(content)) + "\n"
        }
        if inQuote { html += "</div>" }
        return page(css: gothicCSS, body: "<pre class=\"plain\">\(html)</pre>")
    }

    static func wrapHTML(_ html: String, gothic: Bool) -> String {
        let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        if gothic {
            // Invert the email's own colours and turn them back for pictures, then tint it crimson.
            let css = """
            html { background: #F6FAF8 !important; filter: invert(1) hue-rotate(180deg); }
            body { margin: 0; padding: 6px 12px 40px !important; }
            img, video, picture, svg, [style*="background-image"] { filter: invert(1) hue-rotate(180deg); }
            a { color: #9B1B30 !important; }
            img { max-width: 100% !important; height: auto !important; }
            table { max-width: 100% !important; }
            """
            return "<html><head>\(viewport)<style>\(css)</style></head><body>\(html)</body></html>"
        }
        let css = "html,body{background:#fff;} body{margin:0;padding:6px 12px 40px;} img{max-width:100%!important;height:auto!important;}"
        return "<html><head>\(viewport)<style>\(css)</style></head><body>\(html)</body></html>"
    }

    private static func page(css: String, body: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>\(fonts)\(css)</style></head><body>\(body)</body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func linkify(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(https?://[^\s<]+[^\s<.,;:!?)\]'"])"#,
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
    }
}

/// Shows the message body. JavaScript is off; links open in Safari.
struct MessageBodyView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = [.link, .phoneNumber]
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = Theme.uiVoid
        view.scrollView.backgroundColor = Theme.uiVoid
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
