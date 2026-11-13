import EventKit
import SwiftUI

@MainActor
final class CalendarStore: ObservableObject {
    let store = EKEventStore()

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var revision = 0
    @Published var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "vespers.hidden")
            revision += 1
        }
    }

    private var observer: NSObjectProtocol?

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "vespers.hidden") ?? [])
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        if hasAccess { reload() }
    }

    var hasAccess: Bool {
        access == .fullAccess || access == .authorized
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {}
        access = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
            store.reset()
            reload()
        }
    }

    func reload() {
        calendars = store.calendars(for: .event).sorted {
            if $0.source.title != $1.source.title { return $0.source.title < $1.source.title }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        revision += 1
    }

    var visibleCalendars: [EKCalendar] {
        calendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
    }

    var writableCalendars: [EKCalendar] {
        calendars.filter(\.allowsContentModifications)
    }

    var defaultCalendar: EKCalendar? {
        if let preferred = store.defaultCalendarForNewEvents, preferred.allowsContentModifications { return preferred }
        return writableCalendars.first
    }

    /// Events overlapping [start, end), sorted with all-day events first.
    func events(from start: Date, to end: Date) -> [EKEvent] {
        let visible = visibleCalendars
        guard hasAccess, !visible.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visible)
        return store.events(matching: predicate).sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.startDate < b.startDate
        }
    }

    func events(on day: Date) -> [EKEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return events(from: start, to: end)
    }

    /// The days in a range that have at least one event, with up to three colours each.
    func busyDays(from start: Date, to end: Date) -> [Date: [Color]] {
        var result: [Date: [Color]] = [:]
        let calendar = Calendar.current
        for event in events(from: start, to: end) {
            var day = calendar.startOfDay(for: max(event.startDate, start))
            let last = event.endDate > event.startDate ? event.endDate.addingTimeInterval(-1) : event.endDate
            let stop = min(last, end)
            while day <= stop {
                var colours = result[day, default: []]
                if colours.count < 3 { colours.append(Color(cgColor: event.calendar.cgColor)) }
                result[day] = colours
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result
    }

    func save(_ event: EKEvent, span: EKSpan = .thisEvent) throws {
        try store.save(event, span: span, commit: true)
        reload()
    }

    func delete(_ event: EKEvent, span: EKSpan) throws {
        try store.remove(event, span: span, commit: true)
        reload()
    }
}

extension EKEvent: @retroactive Identifiable {
    public var id: String { (eventIdentifier ?? UUID().uuidString) + "|" + String(startDate.timeIntervalSince1970) }
}
