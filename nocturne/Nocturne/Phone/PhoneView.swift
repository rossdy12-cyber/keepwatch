import SwiftUI
import Contacts
import UIKit

struct Person: Identifiable, Hashable {
    let id: String
    let name: String
    let number: String
}

@MainActor
final class ContactsStore: ObservableObject {
    @Published var people: [Person] = []
    @Published var denied = false
    @Published var loaded = false

    func load() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, _ in
            guard ok else { Task { @MainActor in self.denied = true; self.loaded = true }; return }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            var out: [Person] = []
            try? store.enumerateContacts(with: req) { c, _ in
                guard let num = c.phoneNumbers.first?.value.stringValue else { return }
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                out.append(Person(id: c.identifier, name: name.isEmpty ? num : name, number: num))
            }
            out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in self.people = out; self.loaded = true }
        }
    }
}

enum Dialer {
    static func call(_ number: String) {
        let digits = number.filter { "+0123456789*#".contains($0) }
        if let url = URL(string: "tel://\(digits)") { UIApplication.shared.open(url) }
    }
    static func facetime(_ number: String) {
        let digits = number.filter { "+0123456789".contains($0) }
        if let url = URL(string: "facetime://\(digits)") { UIApplication.shared.open(url) }
    }
    static func message(_ number: String) {
        let digits = number.filter { "+0123456789".contains($0) }
        if let url = URL(string: "sms://\(digits)") { UIApplication.shared.open(url) }
    }
}

struct PhoneView: View {
    @EnvironmentObject var store: Store
    @StateObject private var contacts = ContactsStore()
    @AppStorage("favourites") private var favData = ""
    @State private var tab = 0
    @State private var search = ""
    @State private var dialed = ""
    private var theme: GothicTheme { store.theme }

    private var favSet: Set<String> {
        get { Set(favData.split(separator: "|").map(String.init)) }
    }
    private func toggleFav(_ id: String) {
        var s = favSet
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        favData = s.joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 12) {
            GothicTitle(text: "Phone", theme: theme, size: 26).padding(.top, 50)
            Picker("", selection: $tab) {
                Text("Favourites").tag(0); Text("Contacts").tag(1); Text("Dial").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 20)

            switch tab {
            case 0: favourites
            case 1: contactsList
            default: dialPad
            }
            Spacer(minLength: 0)
        }
        .onAppear { if !contacts.loaded { contacts.load() } }
    }

    private var favourites: some View {
        ScrollView {
            if contacts.people.filter({ favSet.contains($0.id) }).isEmpty {
                Text("No favourites yet.\nLong-press a contact to anoint one.")
                    .font(.system(.subheadline, design: .serif)).foregroundStyle(theme.mutedColor)
                    .multilineTextAlignment(.center).padding(40)
            }
            VStack(spacing: 10) {
                ForEach(contacts.people.filter { favSet.contains($0.id) }) { p in
                    row(p)
                }
            }.padding(.horizontal, 16)
        }
    }

    private var contactsList: some View {
        VStack(spacing: 8) {
            TextField("Search", text: $search)
                .padding(10).background(theme.panelColor).clipShape(Capsule())
                .foregroundStyle(theme.textColor).padding(.horizontal, 16)
            if contacts.denied {
                Text("Contacts access denied.\nEnable it in Settings to summon your circle.")
                    .font(.system(.subheadline, design: .serif)).foregroundStyle(theme.mutedColor)
                    .multilineTextAlignment(.center).padding(30)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(filtered) { p in row(p) }
                }.padding(.horizontal, 16)
            }
        }
    }

    private var filtered: [Person] {
        search.isEmpty ? contacts.people : contacts.people.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func row(_ p: Person) -> some View {
        GothicCard(theme: theme) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.accentColor.opacity(0.2)).frame(width: 44, height: 44)
                    Text(initials(p.name)).font(.system(.headline, design: .serif)).foregroundStyle(theme.accentColor)
                }
                VStack(alignment: .leading) {
                    Text(p.name).font(.system(.body, design: .serif)).foregroundStyle(theme.textColor)
                    Text(p.number).font(.caption).foregroundStyle(theme.mutedColor)
                }
                Spacer()
                Button { Dialer.message(p.number) } label: { Image(systemName: "envelope") }
                    .foregroundStyle(theme.mutedColor)
                Button { Dialer.call(p.number) } label: { Image(systemName: "phone.fill") }
                    .foregroundStyle(theme.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button { toggleFav(p.id) } label: {
                Label(favSet.contains(p.id) ? "Remove favourite" : "Anoint favourite",
                      systemImage: favSet.contains(p.id) ? "star.slash" : "star")
            }
            Button { Dialer.facetime(p.number) } label: { Label("FaceTime", systemImage: "video") }
        }
    }

    private var dialPad: some View {
        VStack(spacing: 18) {
            Text(dialed.isEmpty ? " " : dialed)
                .font(.system(size: 36, weight: .light, design: .serif)).foregroundStyle(theme.textColor)
                .frame(height: 44)
            let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
                ForEach(keys, id: \.self) { k in
                    Button { dialed += k } label: {
                        Text(k).font(.system(size: 30, weight: .regular, design: .serif))
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(theme.panelColor))
                            .overlay(Circle().strokeBorder(theme.accentColor.opacity(0.3)))
                            .foregroundStyle(theme.textColor)
                    }
                }
            }
            HStack(spacing: 40) {
                Button { if !dialed.isEmpty { dialed.removeLast() } } label: {
                    Image(systemName: "delete.left").font(.title2).foregroundStyle(theme.mutedColor)
                }
                Button { Dialer.call(dialed) } label: {
                    Image(systemName: "phone.fill").font(.title)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(theme.accentColor)).foregroundStyle(.white)
                }
                .disabled(dialed.isEmpty)
            }
        }
        .padding(.top, 10)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
