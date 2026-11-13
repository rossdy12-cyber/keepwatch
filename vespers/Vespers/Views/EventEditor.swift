import EventKit
import SwiftUI

enum RepeatOption: String, CaseIterable, Identifiable {
    case never, daily, weekly, fortnightly, monthly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .fortnightly: return "Every two weeks"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        }
    }

    init(rule: EKRecurrenceRule?) {
        guard let rule else { self = .never; return }
        switch (rule.frequency, rule.interval) {
        case (.daily, _): self = .daily
        case (.weekly, 2): self = .fortnightly
        case (.weekly, _): self = .weekly
        case (.monthly, _): self = .monthly
        case (.yearly, _): self = .yearly
        default: self = .never
        }
    }

    var rule: EKRecurrenceRule? {
        switch self {
        case .never: return nil
        case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .fortnightly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly: return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

enum AlertOption: Double, CaseIterable, Identifiable {
    case none = 1
    case atTime = 0
    case five = -300
    case fifteen = -900
    case thirty = -1800
    case hour = -3600
    case day = -86400
    case week = -604800
    var id: Double { rawValue }

    static func label(for offset: TimeInterval) -> String {
        AlertOption(rawValue: offset)?.label ?? "\(Int(-offset / 60)) minutes before"
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .atTime: return "At the time"
        case .five: return "5 minutes before"
        case .fifteen: return "15 minutes before"
        case .thirty: return "30 minutes before"
        case .hour: return "1 hour before"
        case .day: return "1 day before"
        case .week: return "1 week before"
        }
    }
}

struct EventDraft: Identifiable {
    let id = UUID()
    var event: EKEvent?
    var title = ""
    var location = ""
    var isAllDay = false
    var start: Date
    var end: Date
    var calendarID: String?
    var repeatOption: RepeatOption = .never
    var alert: AlertOption = .fifteen
    var url = ""
    var notes = ""

    static func new(on day: Date, calendar: EKCalendar?) -> EventDraft {
        let cal = Calendar.current
        var start: Date
        if cal.isDateInToday(day) {
            // The next whole hour.
            let next = cal.date(byAdding: .hour, value: 1, to: Date())!
            start = cal.date(bySettingHour: cal.component(.hour, from: next), minute: 0, second: 0, of: next)!
        } else {
            start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        }
        return EventDraft(start: start, end: start.addingTimeInterval(3600), calendarID: calendar?.calendarIdentifier)
    }

    init(start: Date, end: Date, calendarID: String?) {
        self.start = start
        self.end = end
        self.calendarID = calendarID
    }

    init(event: EKEvent) {
        self.event = event
        title = event.title ?? ""
        location = event.location ?? ""
        isAllDay = event.isAllDay
        start = event.startDate
        let eventEnd: Date = event.endDate
        end = event.isAllDay ? eventEnd.addingTimeInterval(-1) : eventEnd
        calendarID = event.calendar.calendarIdentifier
        repeatOption = RepeatOption(rule: event.recurrenceRules?.first)
        alert = event.alarms?.first.flatMap { AlertOption(rawValue: $0.relativeOffset) } ?? .none
        url = event.url?.absoluteString ?? ""
        notes = event.notes ?? ""
    }
}

struct EventEditor: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: EventDraft
    @State private var error: String?
    @State private var askSpan = false

    private var isNew: Bool { draft.event == nil }

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                Form {
                    Section {
                        TextField("", text: $draft.title, prompt: Text("Title").foregroundStyle(Theme.ash.opacity(0.6)))
                            .font(Theme.serif(20, weight: .semibold))
                        TextField("", text: $draft.location, prompt: Text("Location").foregroundStyle(Theme.ash.opacity(0.6)))
                            .font(Theme.serif(17))
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        Toggle("All day", isOn: $draft.isAllDay.animation())
                        DatePicker("Starts", selection: $draft.start, displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                            .onChange(of: draft.start) { old, new in
                                // Keep the length the same when the start moves.
                                let length = draft.end.timeIntervalSince(old)
                                draft.end = new.addingTimeInterval(max(0, length))
                            }
                        DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                        Picker("Repeat", selection: $draft.repeatOption) {
                            ForEach(RepeatOption.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .font(Theme.serif(17))

                    Section {
                        Picker("Calendar", selection: Binding(get: { draft.calendarID ?? "" }, set: { draft.calendarID = $0 })) {
                            ForEach(store.writableCalendars, id: \.calendarIdentifier) { calendar in
                                HStack {
                                    Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor))
                                    Text(calendar.title)
                                }
                                .tag(calendar.calendarIdentifier)
                            }
                        }
                        Picker("Alert", selection: $draft.alert) {
                            ForEach(AlertOption.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .font(Theme.serif(17))

                    Section {
                        TextField("", text: $draft.url, prompt: Text("Link").foregroundStyle(Theme.ash.opacity(0.6)))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("", text: $draft.notes, prompt: Text("Notes").foregroundStyle(Theme.ash.opacity(0.6)), axis: .vertical)
                            .lineLimit(3...10)
                    }
                    .listRowBackground(Theme.surface)
                    .font(Theme.serif(17))

                    if let error {
                        Text(error)
                            .font(Theme.serif(14))
                            .foregroundStyle(Theme.ember)
                            .listRowBackground(Theme.crimson.opacity(0.15))
                    }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.bone)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle(isNew ? "New Rite" : "Amend Rite")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.font(Theme.engraved(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isNew ? "Add" : "Save") {
                        if let event = draft.event, event.hasRecurrenceRules {
                            askSpan = true
                        } else {
                            save(.thisEvent)
                        }
                    }
                    .font(Theme.engraved(14))
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("This is a repeating event.", isPresented: $askSpan, titleVisibility: .visible) {
                Button("Save for this event only") { save(.thisEvent) }
                Button("Save for future events") { save(.futureEvents) }
            }
        }
        .tint(Theme.blood)
    }

    private func save(_ span: EKSpan) {
        let event = draft.event ?? EKEvent(eventStore: store.store)
        event.title = draft.title.trimmingCharacters(in: .whitespaces)
        event.location = draft.location.isEmpty ? nil : draft.location
        event.isAllDay = draft.isAllDay
        let calendar = Calendar.current
        if draft.isAllDay {
            event.startDate = calendar.startOfDay(for: draft.start)
            event.endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(draft.end, draft.start)))!.addingTimeInterval(-1)
        } else {
            event.startDate = draft.start
            event.endDate = max(draft.end, draft.start)
        }
        if let id = draft.calendarID, let chosen = store.writableCalendars.first(where: { $0.calendarIdentifier == id }) {
            event.calendar = chosen
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendar
        }
        if RepeatOption(rule: event.recurrenceRules?.first) != draft.repeatOption {
            event.recurrenceRules?.forEach { event.removeRecurrenceRule($0) }
            if let rule = draft.repeatOption.rule { event.addRecurrenceRule(rule) }
        }
        event.alarms?.forEach { event.removeAlarm($0) }
        if draft.alert != .none {
            event.addAlarm(EKAlarm(relativeOffset: draft.alert.rawValue))
        }
        let link = draft.url.trimmingCharacters(in: .whitespaces)
        event.url = link.isEmpty ? nil : URL(string: link.contains("://") ? link : "https://" + link)
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        do {
            try store.save(event, span: span)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
