import SwiftUI

struct PaydaysView: View {
    @EnvironmentObject private var store: PaydaysStore
    @EnvironmentObject private var router: AppRouter
    @State private var showingSpendSheet = false
    @State private var showingAddBillSheet = false
    @State private var openWeb: WebDestination?
    @State private var bannerMessage: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let quickMerchants = ["Tesco", "Asda", "Fuel", "Takeaway", "Coffee", "Amazon"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.config.isConfigured {
                        MessageCard(
                            symbol: "sterlingsign.circle",
                            title: "Connect Paydays",
                            message: "Add your Paydays address (e.g. http://100.85.127.42:8450 or https://paydays.nas-server.co.uk) in Settings.",
                            color: Theme.paydaysGreen,
                            actionTitle: "Open Settings"
                        ) {
                            router.tab = .settings
                        }
                    } else {
                        if let error = store.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.warning)
                                .padding(.horizontal, 4)
                        }
                        if let banner = bannerMessage ?? store.lastHookMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.good)
                                Text(banner)
                                    .font(.footnote.weight(.medium))
                                Spacer()
                                Button {
                                    bannerMessage = nil
                                    store.lastHookMessage = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        heroCards
                        quickLogBar
                        recentSpendingCard
                        billsCard
                        siriTipCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable {
                await store.refresh()
            }
            .navigationTitle("Paydays")
            .keepwatchChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let url = URL(string: store.config.baseURL), !store.config.baseURL.isEmpty {
                        Button {
                            openWeb = WebDestination(title: "Paydays Web", url: url)
                        } label: {
                            Label("Web UI", systemImage: "globe")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSpendSheet = true
                    } label: {
                        Label("Spent", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .task {
                if store.config.isConfigured {
                    await store.refresh()
                }
            }
            .sheet(isPresented: $showingSpendSheet) {
                LogSpendSheet(quickMerchants: quickMerchants) { message in
                    bannerMessage = message
                }
            }
            .sheet(isPresented: $showingAddBillSheet) {
                AddBillSheet()
            }
            .fullScreenCover(item: $openWeb) { dest in
                WebScreen(destination: dest, showsDone: true)
            }
        }
    }

    @ViewBuilder
    private var heroCards: some View {
        if let s = store.summary {
            let spentFraction = s.allowancePence > 0 ? Double(s.spentPence) / Double(s.allowancePence) : 0
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    title: "Until \(s.nextPaydayLabel)",
                    value: PaydaysStore.formatPence(s.leftPence),
                    caption: "\(PaydaysStore.formatPence(s.perDayLeftPence))/day · \(s.daysLeft)d left",
                    symbol: "calendar.badge.clock",
                    color: s.leftPence < 0 ? Theme.danger : Theme.level(spentFraction),
                    fraction: min(1.0, max(0.0, spentFraction))
                )
                StatTile(
                    title: "Safe to Spend",
                    value: PaydaysStore.formatPence(s.safePerWeekPence),
                    caption: "\(PaydaysStore.formatPence(s.safePerDayPence))/day steady",
                    symbol: "shield.checkered",
                    color: Theme.paydaysGreen,
                    fraction: nil
                )
            }
            Card(title: "This Pay Period", symbol: "chart.bar.fill", trailing: "\(s.periodStart) → \(s.periodEnd)") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allowance after bills")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text(PaydaysStore.formatPence(s.allowancePence))
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Logged spending")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Text(PaydaysStore.formatPence(s.spentPence))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(s.spentPence > s.allowancePence ? Theme.danger : .white)
                    }
                }
                MeterBar(fraction: spentFraction, color: s.leftPence < 0 ? Theme.danger : Theme.paydaysGreen, height: 10)
            }
        } else if store.isLoading {
            ProgressView("Loading Paydays…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            Card(title: "Paydays Ready", symbol: "sterlingsign.circle") {
                Text("Pull down to refresh your budget data from TrueNAS, or tap + Spent to log a payment right now.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var quickLogBar: some View {
        Button {
            showingSpendSheet = true
        } label: {
            HStack {
                Image(systemName: "applepay")
                    .font(.title2)
                Text("Log Spending (+ Spent)")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.paydaysGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var recentSpendingCard: some View {
        let spends = (store.snapshot?.pays ?? [])
            .filter { $0.kind == "spend" }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            .prefix(10)

        return Card(title: "Recent Spending", symbol: "cart.fill", trailing: spends.isEmpty ? nil : "Last \(spends.count)") {
            if spends.isEmpty {
                Text("No spending logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(Array(spends)) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.source == "applepay" ? "wave.3.right.circle.fill" : "sterlingsign.circle.fill")
                            .foregroundStyle(Theme.paydaysGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.note.isEmpty ? "Spending" : item.note)
                                .font(.subheadline.weight(.medium))
                            Text(item.date)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Text("-" + PaydaysStore.formatPence(item.amount))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.warning)
                        Button(role: .destructive) {
                            Task { await store.deleteSpend(id: item.id) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var billsCard: some View {
        let month = PaydaysStore.currentMonthISO()
        let bills = (store.snapshot?.bills ?? []).filter(\.isActive)
        let paidCount = bills.filter { store.isBillPaid(billID: $0.id, month: month) }.count

        return Card(title: "Monthly Bills (\(month))", symbol: "doc.text.fill", trailing: "\(paidCount)/\(bills.count) paid") {
            HStack {
                Text("Tap a bill when it leaves your account")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    showingAddBillSheet = true
                } label: {
                    Label("Add Bill", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
            }
            if bills.isEmpty {
                Text("No active monthly bills.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(bills) { bill in
                    let isPaid = store.isBillPaid(billID: bill.id, month: month)
                    Button {
                        Task { await store.toggleBillPaid(bill: bill, month: month) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isPaid ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isPaid ? Theme.good : Theme.secondaryText)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bill.name)
                                    .font(.subheadline.weight(.medium))
                                    .strikethrough(isPaid)
                                    .foregroundStyle(isPaid ? Theme.secondaryText : .white)
                                Text("Day \(bill.day)" + (bill.category.isEmpty ? "" : " · \(bill.category)"))
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Text(PaydaysStore.formatPence(bill.amount))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(isPaid ? Theme.secondaryText : .white)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var siriTipCard: some View {
        Card(title: "iOS 27 Action Button / Back-Tap", symbol: "sparkles") {
            Text("Missing the Wallet automation trigger on iOS 27? Open the **Shortcuts** app or **Settings → Accessibility → Touch → Back Tap** and select **Keepwatch → Log Paydays Spend**, or say **\"Hey Siri, log spend in Keepwatch\"** right after paying!")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

struct LogSpendSheet: View {
    let quickMerchants: [String]
    var onLogged: (String) -> Void

    @EnvironmentObject private var store: PaydaysStore
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var merchant = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount (£)") {
                    TextField("e.g. 12.50", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }
                Section("Where / Note") {
                    TextField("Shop or note (e.g. Tesco)", text: $merchant)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickMerchants, id: \.self) { item in
                                Button(item) {
                                    merchant = item
                                }
                                .buttonStyle(.bordered)
                                .tint(merchant == item ? Theme.paydaysGreen : Theme.secondaryText)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(Theme.danger)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .keepwatchChrome()
            .navigationTitle("Log Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(saving || parsedAmount <= 0)
                }
            }
        }
    }

    private var parsedAmount: Double {
        let cleaned = amountText.replacingOccurrences(of: "£", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            let reply = try await store.logSpend(amountPounds: parsedAmount, merchant: merchant)
            onLogged(reply)
            dismiss()
        } catch {
            errorText = describe(error)
        }
    }
}

struct AddBillSheet: View {
    @EnvironmentObject private var store: PaydaysStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amountText = ""
    @State private var day = 1
    @State private var category = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Bill Details") {
                    TextField("Name (e.g. Rent, StepChange)", text: $name)
                    TextField("Monthly Amount (£)", text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker("Day of Month", selection: $day) {
                        ForEach(1...31, id: \.self) { d in
                            Text("Day \(d)").tag(d)
                        }
                    }
                    TextField("Category (optional)", text: $category)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(Theme.danger)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .keepwatchChrome()
            .navigationTitle("New Monthly Bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || (Double(amountText) ?? 0) <= 0)
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            try await store.addBill(
                name: name.trimmingCharacters(in: .whitespaces),
                amountPounds: Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0,
                day: day,
                category: category.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorText = describe(error)
        }
    }
}
