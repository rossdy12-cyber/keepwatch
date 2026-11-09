import SwiftUI

struct MPAddDownloadView: View {
    @EnvironmentObject private var settings: MPAppSettings
    @EnvironmentObject private var router: MPAppRouter

    @State private var url = ""
    @State private var outputType: MPOutputType = .video
    @State private var selectedQuality = "best"
    @State private var folder = "Media/YouTube"
    @State private var formats: [MPMeTubeFormat] = []
    @State private var isLoadingFormats = false
    @State private var isSubmitting = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Download") {
                    TextField("https://example.com/video", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker("Output", selection: $outputType) {
                        ForEach(MPOutputType.allCases) { type in
                            Label(type.displayTitle, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }

                    Picker("Quality", selection: $selectedQuality) {
                        Text("Best").tag("best")

                        ForEach(formats) { format in
                            Text(format.title).tag(format.id)
                        }
                    }

                    TextField("Destination folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        Task { await loadFormats() }
                    } label: {
                        if isLoadingFormats {
                            ProgressView()
                        } else {
                            Label("Refresh formats", systemImage: "arrow.clockwise")
                        }
                    }
                } footer: {
                    Text("Connect to MeTube first in Settings to load its available formats.")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Label("Add to queue", systemImage: "arrow.down.to.line")
                        }
                    }
                    .disabled(url.isEmpty || isSubmitting || !settings.isConfigured)
                } footer: {
                    if !settings.isConfigured {
                        Text("Add your MeTube server URL in Settings before submitting downloads.")
                    }
                }

                if let statusMessage {
                    Section {
                        Label(
                            statusMessage,
                            systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Add Download")
            .onAppear {
                folder = settings.defaultFolder
                consumePendingShareURL()
            }
        }
    }

    private func consumePendingShareURL() {
        guard let sharedURL = router.consumePendingShareURL() else {
            return
        }

        url = sharedURL.absoluteString
    }

    private func loadFormats() async {
        isLoadingFormats = true
        isError = false
        statusMessage = nil

        do {
            let client = MPMeTubeClient(settings: settings)
            formats = try await client.fetchFormats()
            statusMessage = "Loaded \(formats.count) formats."
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }

        isLoadingFormats = false
    }

    private func submit() async {
        isSubmitting = true
        isError = false
        statusMessage = nil

        do {
            let client = MPMeTubeClient(settings: settings)
            try await client.addDownload(
                url: url,
                outputType: outputType,
                quality: selectedQuality,
                folder: folder
            )

            settings.defaultFolder = folder
            statusMessage = "Download added to MeTube."
            url = ""
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}

#Preview {
    MPAddDownloadView()
        .environmentObject(MPAppSettings())
        .environmentObject(MPAppRouter())
}
