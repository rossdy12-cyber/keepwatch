import SwiftUI

struct UserScriptsView: View {
    @ObservedObject var store = UserScriptStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: UserScript?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.scripts.isEmpty {
                        Text("No userscripts").foregroundStyle(Crimson.muted).listRowBackground(Crimson.panel)
                    }
                    ForEach(store.scripts) { s in
                        Button { editing = s } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).foregroundStyle(Crimson.text).lineLimit(1)
                                    Text(s.pattern).font(.caption).foregroundStyle(Crimson.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: s.enabled ? "circle.fill" : "circle")
                                    .font(.caption).foregroundStyle(s.enabled ? Crimson.accent2 : Crimson.muted)
                            }
                        }
                        .listRowBackground(Crimson.panel)
                    }
                    .onDelete { idx in idx.map { store.scripts[$0] }.forEach(store.delete) }
                } footer: {
                    Text("Userscripts are custom JavaScript injected into pages whose URL matches the pattern (use * as a wildcard). They run after each page loads.")
                        .foregroundStyle(Crimson.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("Userscripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { editing = store.add() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { s in ScriptEditor(script: s).tint(Crimson.accent) }
        }
        .tint(Crimson.accent)
    }
}

private struct ScriptEditor: View {
    @ObservedObject var store = UserScriptStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var script: UserScript

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $script.name).foregroundStyle(Crimson.text)
                }.listRowBackground(Crimson.panel)
                Section("Match pattern") {
                    TextField("*://*.example.com/*", text: $script.pattern)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(Crimson.text)
                    Toggle("Enabled", isOn: $script.enabled).tint(Crimson.accent)
                }.listRowBackground(Crimson.panel)
                Section("JavaScript") {
                    TextEditor(text: $script.code)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Crimson.text)
                        .scrollContentBackground(.hidden)
                }.listRowBackground(Crimson.panel)
            }
            .scrollContentBackground(.hidden)
            .background(Crimson.bg.ignoresSafeArea())
            .navigationTitle("Edit Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { store.update(script); dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
