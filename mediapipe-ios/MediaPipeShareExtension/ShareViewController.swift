import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    private let appGroupID = "group.uk.co.rossdymond.mediapipe"
    private let serverKey = "shareExtension.serverBaseURL"
    private let tokenKey = "shareExtension.apiToken"
    private let folderKey = "shareExtension.defaultFolder"
    private let outputKey = "shareExtension.outputType"
    private let qualityKey = "shareExtension.quality"

    private var sharedURL: URL?

    override func isContentValid() -> Bool {
        extractedURL() != nil
    }

    override func didSelectPost() {
        guard let url = extractedURL() else {
            completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        guard let defaults = UserDefaults(suiteName: appGroupID),
              let baseURL = defaults.string(forKey: serverKey),
              !baseURL.isEmpty else {
            show(message: "Open MediaPipe and configure the MeTube server first.")
            return
        }

        let token = defaults.string(forKey: tokenKey) ?? ""
        let folder = defaults.string(forKey: folderKey) ?? "Media/YouTube"
        let outputType = defaults.string(forKey: outputKey) ?? "video"
        let quality = defaults.string(forKey: qualityKey) ?? "best"

        var components = URLComponents(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/add")

        guard components != nil else {
            show(message: "The configured MeTube URL is invalid.")
            return
        }

        var request = URLRequest(url: components!.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "url": url.absoluteString,
            "format": outputType,
            "quality": quality,
            "folder": folder,
            "custom_name_prefix": ""
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    show(message: "MeTube rejected the download (HTTP \(status)).")
                    return
                }

                show(message: "Added to MeTube: \(folder)")
            } catch {
                show(message: error.localizedDescription)
            }
        }
    }

    override func configurationItems() -> [Any]! {
        []
    }

    private func show(message: String) {
        let alert = UIAlertController(
            title: "MediaPipe",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.completeRequest(returningItems: [], completionHandler: nil)
        })

        present(alert, animated: true)
    }

    private func extractedURL() -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }

        for item in items {
            guard let attachments = item.attachments else {
                continue
            }

            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                        Task { @MainActor in
                            if let url = item as? URL {
                                self?.sharedURL = url
                            } else if let string = item as? String, let url = URL(string: string) {
                                self?.sharedURL = url
                            }
                        }
                    }
                }

                if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                        Task { @MainActor in
                            if let text = item as? String,
                               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                               url.scheme == "http" || url.scheme == "https" {
                                self?.sharedURL = url
                            }
                        }
                    }
                }
            }
        }

        return sharedURL
    }
}
