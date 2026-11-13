import EventKit
import SwiftUI

// MARK: Agenda

struct AgendaView: View {
    @EnvironmentObject private var store: CalendarStore
    let start: Date
    let open: (EKEvent) -> Void
    @State private var days = 60

    var body: some View {
        let _ = store.revision
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: start)
        let to = calendar.date(byAdding: .day, value: days, to: from)!
        let events = store.events(from: from, to: to)
        let grouped = Dictionary(grouping: events) { (event: EKEvent) -> Date in
            let eventStart: Date = event.startDate
            return calendar.startOfDay(for: max(eventStart, from))
        }
        let keys = grouped.keys.sorted()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                if keys.isEmpty {
                    VStack(spacing: 12) {
                        Text("✠").font(.system(size: 34)).foregroundStyle(Theme.crimson)
                        Text("A quiet season")
                            .font(Theme.gothic(32))
                            .foregroundStyle(Theme.bone)
                        Text("Nothing in the next \(days) days.")
                            .font(Theme.serifItalic(16))
                            .foregroundStyle(Theme.ash)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
                ForEach(keys, id: \.self) { day in
                    Section {
                        ForEach(grouped[day] ?? []) { event in
                            Button { open(event) } label: { EventRow(event: event, day: day) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 14)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(Theme.gothic(30))
                                .foregroundStyle(calendar.isDateInToday(day) ? Theme.ember : Theme.bone)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(day.formatted(.dateTime.weekday(.wide)).uppercased())
                                    .font(Theme.engraved(12))
                                    .tracking(1.5)
                                    .foregroundStyle(calendar.isDateInToday(day) ? Theme.ember : Theme.bone)
                                Text(day.formatted(.dateTime.month(.wide)) + " " + Roman.numeral(calendar.component(.year, from: day)))
                                    .font(Theme.engraved(10))
                                    .foregroundStyle(Theme.ash)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(LinearGradient(colors: [Theme.void, Theme.void.opacity(0.9), Theme.void.opacity(0)], startPoint: .top, endPoint: .bottom))
                    }
                }
                if !keys.isEmpty {
                    Button("Look further ahead") { days += 90 }
                        .font(Theme.engraved(13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: Detail

struct EventDetailView: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss
    let event: EKEvent
    @State private var editing: EventDraft?
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        let _ = store.revision
        ZStack {
            GothicBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(cgColor: event.calendar.cgColor))
                            .frame(width: 5)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.displayTitle)
                                .font(Theme.serif(28, weight: .semibold))
                                .foregroundStyle(Theme.bone)
                                .textSelection(.enabled)
                            Text(event.calendar.title.uppercased())
                                .font(Theme.engraved(11))
                                .tracking(2)
                                .foregroundStyle(Theme.ash)
                        }
                    }
                    OrnamentDivider()
                    detail("When", whenText, symbol: "hourglass")
                    if let location = event.location, !location.isEmpty {
                        detail("Where", location, symbol: "mappin.and.ellipse")
                    }
                    if let rule = event.recurrenceRules?.first {
                        detail("Repeats", RepeatOption(rule: rule).label, symbol: "repeat")
                    }
                    if let alarms = event.alarms, !alarms.isEmpty {
                        detail("Alerts", alarms.map { AlertOption.label(for: $0.relativeOffset) }.joined(separator: ", "), symbol: "bell")
                    }
                    if let url = event.url {
                        detail("Link", url.absoluteString, symbol: "link")
                    }
                    if let notes = event.notes, !notes.isEmpty {
                        detail("Notes", notes, symbol: "text.quote")
                    }
                    if let error {
                        Text(error).font(Theme.serif(14)).foregroundStyle(Theme.ember)
                    }
                    if event.calendar.allowsContentModifications {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text("Delete event")
                        }
                        .buttonStyle(CrimsonButtonStyle(filled: false))
                        .padding(.top, 10)
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if event.calendar.allowsContentModifications {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = EventDraft(event: event) }
                        .font(Theme.engraved(14))
                }
            }
        }
        .sheet(item: $editing) { draft in
            EventEditor(draft: draft)
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if event.hasRecurrenceRules {
                Button("Delete this event only", role: .destructive) { delete(.thisEvent) }
                Button("Delete all future events", role: .destructive) { delete(.futureEvents) }
            } else {
                Button("Delete event", role: .destructive) { delete(.thisEvent) }
            }
        }
    }

    private var whenText: String {
        let calendar = Calendar.current
        if event.isAllDay {
            let last = event.endDate.addingTimeInterval(-1)
            if calendar.isDate(event.startDate, inSameDayAs: last) {
                return event.startDate.formatted(date: .complete, time: .omitted) + "\nAll day"
            }
            return event.startDate.formatted(date: .long, time: .omitted) + " –\n" + last.formatted(date: .long, time: .omitted)
        }
        if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
            return event.startDate.formatted(date: .complete, time: .omitted) + "\n"
                + event.startDate.formatted(date: .omitted, time: .shortened) + " – " + event.endDate.formatted(date: .omitted, time: .shortened)
        }
        return event.startDate.formatted(date: .long, time: .shortened) + " –\n" + event.endDate.formatted(date: .long, time: .shortened)
    }

    private func detail(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(Theme.blood)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(Theme.engraved(11))
                    .tracking(2)
                    .foregroundStyle(Theme.ash)
                Text(value)
                    .font(Theme.serif(17))
                    .foregroundStyle(Theme.bone)
                    .textSelection(.enabled)
            }
        }
    }

    private func delete(_ span: EKSpan) {
        do {
            try store.delete(event, span: span)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Calendars

struct CalendarsSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GothicBackground()
                List {
                    ForEach(groupedSources, id: \.0) { source, calendars in
                        Section {
                            ForEach(calendars, id: \.calendarIdentifier) { calendar in
                                let shown = !store.hiddenCalendarIDs.contains(calendar.calendarIdentifier)
                                Button {
                                    if shown {
                                        store.hiddenCalendarIDs.insert(calendar.calendarIdentifier)
                                    } else {
                                        store.hiddenCalendarIDs.remove(calendar.calendarIdentifier)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: shown ? "circle.inset.filled" : "circle")
                                            .foregroundStyle(Color(cgColor: calendar.cgColor))
                                        Text(calendar.title)
                                            .font(Theme.serif(17))
                                            .foregroundStyle(shown ? Theme.bone : Theme.ash)
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Theme.surface)
                            }
                        } header: {
                            Text(source.uppercased())
                                .font(Theme.engraved(12))
                                .tracking(2)
                                .foregroundStyle(Theme.ash)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
            .gothicTitle("Calendars")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(Theme.engraved(14))
                }
            }
        }
    }

    private var groupedSources: [(String, [EKCalendar])] {
        var order: [String] = []
        var groups: [String: [EKCalendar]] = [:]
        for calendar in store.calendars {
            let source = calendar.source.title
            if groups[source] == nil { order.append(source) }
            groups[source, default: []].append(calendar)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
