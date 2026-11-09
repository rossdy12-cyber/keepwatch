import UIKit
import Social
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: SLComposeServiceViewController {
    private var sharedURL: URL?
    private var loading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        loading = true
        Task { @MainActor in
            await loadURL()
            loading = false
            validateContent()
        }
    }

    override func isContentValid() -> Bool { !loading && sharedURL != nil }
    override func configurationItems() -> [Any]! { [] }

    private func item(from provider: NSItemProvider, type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    private func validURL(_ value: NSSecureCoding?) -> URL? {
        let raw: String
        if let url = value as? URL { raw = url.absoluteString }
        else if let text = value as? String { raw = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { return nil }
        guard let c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        return c.url
    }

    private func loadURL() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for input in items {
            for provider in input.attachments ?? [] {
                for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    if let url = validURL(await item(from: provider, type: type)) { sharedURL = url; return }
                }
            }
        }
    }

    override func didSelectPost() {
        guard let url = sharedURL else { return }
        do {
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.uk.co.rossdymond.linkvault") else {
                throw NSError(domain: "LinkVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "The shared App Group is unavailable."])
            }
            let inbox = root.appendingPathComponent("PendingLinks", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let file = inbox.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
            try JSONEncoder().encode(url.absoluteString).write(to: file, options: .atomic)
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } catch {
            let alert = UIAlertController(title: "Could not save link", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
