import EventKit
import SwiftUI

@main
struct VespersApp: App {
    @StateObject private var store = CalendarStore()

    init() {
        Theme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.hasAccess {
                    CalendarHome()
                } else {
                    AccessView()
                }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.blood)
        }
    }
}

struct AccessView: View {
    @EnvironmentObject private var store: CalendarStore

    var body: some View {
        ZStack {
            GothicBackground()
            VStack(spacing: 22) {
                Text("✠")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.blood)
                    .shadow(color: Theme.blood, radius: 12)
                Text("Vespers")
                    .font(Theme.gothic(72))
                    .foregroundStyle(LinearGradient(colors: [Theme.bone, Theme.ember], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.crimson, radius: 18)
                Text("THE HOURS, KEPT")
                    .font(Theme.engraved(12))
                    .tracking(4)
                    .foregroundStyle(Theme.ash)
                OrnamentDivider().padding(.horizontal, 30)
                Text(store.access == .notDetermined
                     ? "Vespers shows the calendars already on this iPhone: iCloud, Google, Outlook and any others in Settings."
                     : "Vespers needs full access to your calendars. Open Settings → Apps → Vespers → Calendars and choose Full Access.")
                    .font(Theme.serifItalic(16))
                    .foregroundStyle(Theme.ash)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button {
                    if store.access == .notDetermined {
                        Task { await store.requestAccess() }
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text(store.access == .notDetermined ? "Open the Book of Hours" : "Open Settings")
                }
                .buttonStyle(CrimsonButtonStyle())
                .padding(.horizontal, 30)
            }
        }
    }
}

enum CalendarMode: String, CaseIterable {
    case month = "Month"
    case agenda = "Agenda"
}

struct CalendarHome: View {
    @EnvironmentObject private var store: CalendarStore
    @AppStorage("vespers.mode") private var mode: CalendarMode = .month
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var editing: EventDraft?
    @State private var showCalendars = false
    @State private var path: [EventRef] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GothicBackground()
                switch mode {
                case .month:
                    MonthView(month: $month, selected: $selected) { event in
                        path.append(EventRef(event: event))
                    }
                case .agenda:
                    AgendaView(start: selected) { event in
                        path.append(EventRef(event: event))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCalendars = true
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityLabel("Calendars")
                }
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(CalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Today") {
                        let today = Calendar.current.startOfDay(for: Date())
                        withAnimation {
                            selected = today
                            month = Calendar.current.dateInterval(of: .month, for: today)!.start
                        }
                    }
                    .font(Theme.engraved(13))
                    Button {
                        editing = EventDraft.new(on: selected, calendar: store.defaultCalendar)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New event")
                    .disabled(store.defaultCalendar == nil)
                }
            }
            .navigationDestination(for: EventRef.self) { ref in
                EventDetailView(event: ref.event)
            }
            .sheet(item: $editing) { draft in
                EventEditor(draft: draft)
            }
            .sheet(isPresented: $showCalendars) {
                CalendarsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.void)
            }
        }
    }
}

/// Hashable wrapper so events can be pushed onto the navigation stack.
struct EventRef: Hashable {
    let event: EKEvent
    static func == (a: EventRef, b: EventRef) -> Bool { a.event === b.event }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(event)) }
}
