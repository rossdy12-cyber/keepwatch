import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Draft
    @State private var sending = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var showCc = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingAttachments = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject, body }

    /// Most servers refuse messages over about 25 MB once encoded.
    private static let sizeWarning = 18 * 1024 * 1024

    init(draft: Draft) {
        _draft = State(initialValue: draft)
        _showCc = State(initialValue: !draft.cc.isEmpty)
    }

    private var isEmpty: Bool {
        draft.to.isEmpty && draft.cc.isEmpty && draft.subject.isEmpty && draft.attachments.isEmpty
            && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var attachmentBytes: Int { draft.attachments.reduce(0) { $0 + $1.data.count } }

    private var fromAccount: MailAccount? {
        store.accounts.first { $0.id == draft.accountID } ?? store.account
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                VStack(spacing: 0) {
                    if store.accounts.count > 1 {
                        fromRow
                    }
                    addressRow("To", text: $draft.to, field: .to) {
                        if !showCc {
                            Button("Cc") { showCc = true; focus = .cc }
                                .font(Theme.engraved(12))
                        }
                    }
                    if showCc {
                        addressRow("Cc", text: $draft.cc, field: .cc) { EmptyView() }
                    }
                    TextField("", text: $draft.subject, prompt: Text("Subject").foregroundStyle(Theme.ash.opacity(0.6)))
                        .font(Theme.serif(19, weight: .semibold))
                        .foregroundStyle(Theme.bone)
                        .focused($focus, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { focus = .body }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)

                    if !draft.attachments.isEmpty || loadingAttachments {
                        attachmentStrip
                    }

                    OrnamentDivider()
                        .padding(.horizontal, 18)

                    if let error {
                        Text(error)
                            .font(Theme.serif(14))
                            .foregroundStyle(Theme.ember)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Theme.crimson.opacity(0.18))
                    }

                    TextEditor(text: $draft.body)
                        .font(Theme.serif(17))
                        .foregroundStyle(Theme.bone)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($focus, equals: .body)
                        .padding(.horizontal, 13)
                        .padding(.top, 6)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle(draft.subject.isEmpty ? "New Letter" : draft.subject)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if isEmpty { dismiss() } else { confirmDiscard = true }
                    }
                    .font(Theme.engraved(14))
                    .disabled(sending)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showPhotos = true
                        } label: { Label("Photos and Videos", systemImage: "photo.on.rectangle") }
                        Button {
                            showFiles = true
                        } label: { Label("Files", systemImage: "folder") }
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .disabled(sending)
                    .accessibilityLabel("Attach")

                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().tint(Theme.blood)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(sending || loadingAttachments || (draft.to.isEmpty && draft.cc.isEmpty))
                    .accessibilityLabel("Send")
                }
            }
            .confirmationDialog("Discard this letter?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await addPhotos(items) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): addFiles(urls)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .onAppear {
                focus = draft.to.isEmpty ? .to : .body
            }
        }
        .tint(Theme.blood)
    }

    // MARK: Rows

    private var fromRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("FROM")
                    .font(Theme.engraved(12))
                    .tracking(1.5)
                    .foregroundStyle(Theme.ash)
                    .frame(width: 44, alignment: .leading)
                Menu {
                    ForEach(store.accounts) { account in
                        Button {
                            draft.accountID = account.id
                        } label: {
                            if account.id == fromAccount?.id {
                                Label(account.email, systemImage: "checkmark")
                            } else {
                                Text(account.email)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(fromAccount?.email ?? "")
                            .font(Theme.serif(17))
                            .foregroundStyle(Theme.bone)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ash)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func addressRow<Accessory: View>(_ label: String, text: Binding<String>, field: Field, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label.uppercased())
                    .font(Theme.engraved(12))
                    .tracking(1.5)
                    .foregroundStyle(Theme.ash)
                    .frame(width: store.accounts.count > 1 ? 44 : 30, alignment: .leading)
                TextField("", text: text, prompt: Text("name@example.com").foregroundStyle(Theme.ash.opacity(0.4)))
                    .font(Theme.serif(17))
                    .foregroundStyle(Theme.bone)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: field)
                    .submitLabel(.next)
                    .onSubmit { focus = .subject }
                accessory()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var attachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.attachments) { item in
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: item))
                            Text(item.filename).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                                .foregroundStyle(Theme.ash)
                            Button {
                                draft.attachments.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.ash)
                            }
                            .accessibilityLabel("Remove \(item.filename)")
                        }
                        .font(Theme.serif(13))
                        .foregroundStyle(Theme.bone)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.crimson))
                    }
                    if loadingAttachments {
                        ProgressView().tint(Theme.blood).padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 18)
            }
            if attachmentBytes > Self.sizeWarning {
                Text("These attachments total \(ByteCountFormatter.string(fromByteCount: Int64(attachmentBytes), countStyle: .file)). Many mail servers refuse letters this large.")
                    .font(Theme.serifItalic(12))
                    .foregroundStyle(Theme.ember)
                    .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 10)
    }

    private func icon(for item: Attachment) -> String {
        if item.mimeType.hasPrefix("image/") { return "photo" }
        if item.mimeType.hasPrefix("video/") { return "film" }
        if item.mimeType == "application/pdf" { return "doc.richtext" }
        return "paperclip"
    }

    // MARK: Attachments

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        loadingAttachments = true
        defer { loadingAttachments = false }
        for item in items {
            do {
                guard var data = try await item.loadTransferable(type: Data.self) else { continue }
                var type = item.supportedContentTypes.first ?? .data
                // Send HEIC photos as JPEG so every mail app can show them.
                if type.conforms(to: .image), !type.conforms(to: .jpeg), !type.conforms(to: .png), !type.conforms(to: .gif),
                   let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    data = jpeg
                    type = .jpeg
                }
                let ext = type.preferredFilenameExtension ?? "dat"
                let kind = type.conforms(to: .movie) ? "Video" : "Photo"
                let number = draft.attachments.count + 1
                let name = items.count == 1 && number == 1 ? "\(kind).\(ext)" : "\(kind) \(number).\(ext)"
                draft.attachments.append(Attachment(filename: name, mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data))
            } catch {
                self.error = "Couldn't add that item: \(error.localizedDescription)"
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)
                draft.attachments.append(Attachment(
                    filename: url.lastPathComponent,
                    mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                    data: data
                ))
            } catch {
                self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await store.send(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
