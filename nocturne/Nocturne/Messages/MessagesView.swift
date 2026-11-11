import SwiftUI
import MessageUI
import UIKit

struct RelayMessage: Identifiable, Decodable {
    let id: Int
    let sender: String
    let text: String
    let ts: Double
}

@MainActor
final class RelayClient: ObservableObject {
    @Published var messages: [RelayMessage] = []
    @Published var status = ""
    private var timer: Timer?
    private var lastID = 0

    func base(_ store: Store) -> String { ServerAddress.normalize(store.relayURL) }

    func start(_ store: Store) {
        stop()
        guard !base(store).isEmpty else { status = "Set a relay server in the Altar."; return }
        poll(store)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(store) }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func req(_ store: Store, _ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: base(store) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        if !store.relayToken.isEmpty { r.setValue("Bearer \(store.relayToken)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    func poll(_ store: Store) {
        guard let r = req(store, "/api/relay/messages?room=\(store.chatRoom)&since=\(lastID)") else { return }
        netSession.dataTask(with: r) { data, _, err in
            guard let data, let arr = try? JSONDecoder().decode([RelayMessage].self, from: data) else {
                if err != nil { Task { @MainActor in self.status = "Relay unreachable." } }
                return
            }
            Task { @MainActor in
                if !arr.isEmpty {
                    self.messages.append(contentsOf: arr)
                    self.lastID = arr.map(\.id).max() ?? self.lastID
                }
                self.status = ""
            }
        }.resume()
    }

    func send(_ store: Store, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let r = req(store, "/api/relay/send", method: "POST",
            body: ["room": store.chatRoom, "sender": store.displayName, "text": t]) else { return }
        netSession.dataTask(with: r) { _, _, _ in Task { @MainActor in self.poll(store) } }.resume()
    }
}

struct MessagesView: View {
    @EnvironmentObject var store: Store
    @StateObject private var relay = RelayClient()
    @State private var draft = ""
    @State private var showSMS = false
    @State private var smsNumber = ""
    @State private var askNumber = false
    private var theme: GothicTheme { store.theme }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                GothicTitle(text: "Messages", theme: theme, size: 26)
                Spacer()
                Menu {
                    Button { askNumber = true } label: { Label("Quick SMS", systemImage: "bubble.left") }
                    Text("Room: \(store.chatRoom)")
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 20).padding(.top, 50).padding(.bottom, 8)

            if !relay.status.isEmpty {
                Text(relay.status).font(.caption).foregroundStyle(theme.mutedColor).padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(relay.messages) { m in bubble(m) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .onChange(of: relay.messages.count) { _ in
                        if let last = relay.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            composer
        }
        .onAppear { relay.start(store) }
        .onDisappear { relay.stop() }
        .sheet(isPresented: $showSMS) { SMSComposer(recipients: [smsNumber]) }
        .alert("Quick SMS", isPresented: $askNumber) {
            TextField("Phone number", text: $smsNumber).keyboardType(.phonePad)
            Button("Compose") { if MFMessageComposeViewController.canSendText() { showSMS = true } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Opens Apple's message sheet to send a real SMS.") }
    }

    private func bubble(_ m: RelayMessage) -> some View {
        let mine = m.sender == store.displayName
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine {
                    Text(m.sender).font(.caption2).foregroundStyle(theme.accent2Color)
                }
                Text(m.text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(mine ? .white : theme.textColor)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(mine ? theme.accentColor : theme.panelColor)
                    )
            }
            if !mine { Spacer(minLength: 40) }
        }
        .id(m.id)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Speak into the dark…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(theme.panelColor).clipShape(RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(theme.textColor)
            Button {
                relay.send(store, draft); draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(theme.accentColor)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.bgColors.last ?? .black)
    }
}

/// Apple's SMS compose sheet (its UI, unthemeable — this is the only way to send a real SMS).
struct SMSComposer: UIViewControllerRepresentable {
    let recipients: [String]
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients.filter { !$0.isEmpty }
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
        }
    }
}
