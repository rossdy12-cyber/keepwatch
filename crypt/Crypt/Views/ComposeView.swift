import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Draft
    @State private var sending = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var showCc = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject, body }

    init(draft: Draft) {
        _draft = State(initialValue: draft)
        _showCc = State(initialValue: !draft.cc.isEmpty)
    }

    private var isEmpty: Bool {
        draft.to.isEmpty && draft.cc.isEmpty && draft.subject.isEmpty && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                VStack(spacing: 0) {
                    addressRow("To", text: $draft.to, field: .to) {
                        if !showCc {
                            Button("Cc") { showCc = true; focus = .cc }
                                .font(Theme.engraved(12))
                        }
                    }
                    if showCc {
                        addressRow("Cc", text: $draft.cc, field: .cc) { EmptyView() }
                    }
                    HStack {
                        TextField("", text: $draft.subject, prompt: Text("Subject").foregroundStyle(Theme.ash.opacity(0.6)))
                            .font(Theme.serif(19, weight: .semibold))
                            .foregroundStyle(Theme.bone)
                            .focused($focus, equals: .subject)
                            .submitLabel(.next)
                            .onSubmit { focus = .body }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().tint(Theme.blood)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(sending || (draft.to.isEmpty && draft.cc.isEmpty))
                    .accessibilityLabel("Send")
                }
            }
            .confirmationDialog("Discard this letter?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .onAppear {
                focus = draft.to.isEmpty ? .to : .body
            }
        }
        .tint(Theme.blood)
    }

    private func addressRow<Accessory: View>(_ label: String, text: Binding<String>, field: Field, @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label.uppercased())
                    .font(Theme.engraved(12))
                    .tracking(1.5)
                    .foregroundStyle(Theme.ash)
                    .frame(width: 30, alignment: .leading)
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
