import PhotosUI
import SwiftUI

struct PVUploadView: View {
    let client: PVPhotoPrismClient

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploadTasks: [PVUploadTask] = []
    @State private var isUploading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $pickerItems, matching: .any(of: [.images, .videos])) {
                        Label("Choose photos or videos", systemImage: "photo.badge.plus")
                    }
                }

                if !uploadTasks.isEmpty {
                    Section("Upload queue") {
                        ForEach(uploadTasks) { task in
                            HStack {
                                Image(systemName: task.status.systemImage)
                                    .foregroundStyle(task.status.color)

                                VStack(alignment: .leading) {
                                    Text(task.name)
                                        .lineLimit(1)

                                    if let message = task.message {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await uploadSelected() }
                    } label: {
                        if isUploading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Upload \(pickerItems.count) item(s)")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(pickerItems.isEmpty || isUploading)
                }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func uploadSelected() async {
        isUploading = true
        uploadTasks = []

        for item in pickerItems {
            let name = item.itemIdentifier ?? UUID().uuidString
            var task = PVUploadTask(id: UUID(), name: name, status: .waiting)
            uploadTasks.append(task)

            do {
                let data = try await item.loadTransferable(type: Data.self)

                guard let data, !data.isEmpty else {
                    throw PVPhotoPrismError(message: "Could not read the selected item.")
                }

                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("photovault-\(UUID().uuidString).dat")
                try data.write(to: temporaryURL)

                task.status = .uploading
                update(task)

                try await client.uploadFile(at: temporaryURL, originalName: name)
                try? FileManager.default.removeItem(at: temporaryURL)

                task.status = .uploaded
                update(task)
            } catch {
                task.status = .failed
                task.message = error.localizedDescription
                update(task)
            }
        }

        do {
            try await client.importUploads()
        } catch {
            uploadTasks.append(PVUploadTask(
                id: UUID(),
                name: "Import",
                status: .failed,
                message: error.localizedDescription
            ))
        }

        isUploading = false
    }

    private func update(_ task: PVUploadTask) {
        if let index = uploadTasks.firstIndex(where: { $0.id == task.id }) {
            uploadTasks[index] = task
        }
    }
}

struct PVUploadTask: Identifiable {
    let id: UUID
    let name: String
    var status: PVUploadStatus
    var message: String?
}

enum PVUploadStatus {
    case waiting
    case uploading
    case uploaded
    case failed

    var systemImage: String {
        switch self {
        case .waiting: return "clock"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return .secondary
        case .uploading: return .blue
        case .uploaded: return .green
        case .failed: return .red
        }
    }
}
