import EventKit
import SwiftUI

struct MonthView: View {
    @EnvironmentObject private var store: CalendarStore
    @Binding var month: Date
    @Binding var selected: Date
    let open: (EKEvent) -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    /// Every day shown in the grid: whole weeks covering the month.
    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: interval.start),
              let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: interval.end.addingTimeInterval(-1)) else { return [] }
        var result: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let grid = days
        let busy = grid.isEmpty ? [:] : store.busyDays(from: grid.first!, to: calendar.date(byAdding: .day, value: 1, to: grid.last!)!)
        let _ = store.revision
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(Theme.engraved(11))
                        .foregroundStyle(Theme.ash)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(grid, id: \.self) { day in
                    DayCell(
                        day: day,
                        inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                        isSelected: calendar.isDate(day, inSameDayAs: selected),
                        isToday: calendar.isDateInToday(day),
                        colours: busy[calendar.startOfDay(for: day)] ?? []
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { selected = day }
                        if !calendar.isDate(day, equalTo: month, toGranularity: .month) {
                            withAnimation { month = calendar.dateInterval(of: .month, for: day)!.start }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    shift(value.translation.width < 0 ? 1 : -1)
                }
            )
            OrnamentDivider()
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            DayEventsList(day: selected, open: open)
        }
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Spacer()
            VStack(spacing: 0) {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(Theme.gothic(38))
                    .foregroundStyle(Theme.bone)
                    .shadow(color: Theme.crimson, radius: 10)
                Text(Roman.numeral(calendar.component(.year, from: month)))
                    .font(Theme.engraved(13))
                    .tracking(4)
                    .foregroundStyle(Theme.ember)
            }
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .font(.system(size: 18, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private func shift(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            month = next
            // Keep the same day number in the new month where possible.
            let day = min(calendar.component(.day, from: selected), calendar.range(of: .day, in: .month, for: next)?.count ?? 28)
            selected = calendar.date(bySetting: .day, value: day, of: next).map { calendar.startOfDay(for: $0) } ?? next
        }
    }
}

struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let colours: [Color]

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(Theme.serif(18, weight: isToday || isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.bone : (inMonth ? Theme.bone : Theme.ash.opacity(0.4)))
                .frame(width: 36, height: 36)
                .background {
                    if isSelected {
                        Circle().fill(LinearGradient(colors: [Theme.blood, Theme.crimson], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.blood.opacity(0.7), radius: 8)
                    } else if isToday {
                        Circle().strokeBorder(Theme.blood, lineWidth: 1.5)
                    }
                }
            HStack(spacing: 3) {
                ForEach(Array(colours.enumerated()), id: \.offset) { _, colour in
                    Circle().fill(colour).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(day.formatted(date: .complete, time: .omitted) + (colours.isEmpty ? "" : ", has events")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct DayEventsList: View {
    @EnvironmentObject private var store: CalendarStore
    let day: Date
    let open: (EKEvent) -> Void

    var body: some View {
        let _ = store.revision
        let events = store.events(on: day)
        VStack(alignment: .leading, spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Theme.engraved(13))
                .tracking(1.5)
                .foregroundStyle(Theme.ash)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            if events.isEmpty {
                Text("No rites observed this day.")
                    .font(Theme.serifItalic(16))
                    .foregroundStyle(Theme.ash.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(events) { event in
                            Button { open(event) } label: { EventRow(event: event, day: day) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

struct EventRow: View {
    let event: EKEvent
    var day: Date?

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let calendar = Calendar.current
        if let day, !calendar.isDate(event.startDate, inSameDayAs: day) {
            return calendar.isDate(event.endDate, inSameDayAs: day) ? "Until \(event.endDate.formatted(date: .omitted, time: .shortened))" : "All day"
        }
        return event.startDate.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 4)
                .shadow(color: Color(cgColor: event.calendar.cgColor).opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayTitle)
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(2)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(Theme.serifItalic(14))
                        .foregroundStyle(Theme.ash)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeText)
                    .font(Theme.engraved(12))
                    .foregroundStyle(Theme.ember)
                if !event.isAllDay, day == nil || Calendar.current.isDate(event.startDate, inSameDayAs: day!) {
                    Text(event.endDate.formatted(date: .omitted, time: .shortened))
                        .font(Theme.engraved(11))
                        .foregroundStyle(Theme.ash)
                }
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

enum Roman {
    static func numeral(_ value: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var out = ""
        for (number, letters) in table {
            while remaining >= number { out += letters; remaining -= number }
        }
        return out
    }
}

extension EKEvent {
    var displayTitle: String {
        let text = (title ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "(untitled)" : text
    }
}
