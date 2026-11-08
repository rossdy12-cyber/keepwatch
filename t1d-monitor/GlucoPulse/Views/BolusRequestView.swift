import SwiftUI

struct BolusRequestView: View {
    @EnvironmentObject private var store: GlucoStore
    @EnvironmentObject private var bolusService: BolusRequestService
    @Environment(\.dismiss) private var dismiss

    @State private var totalUnits: Double = 0
    @State private var carbsGrams: Double = 0
    @State private var durationHours: Int = 2
    @State private var distribution: ExtendedBolusDistribution = .immediate
    @State private var confirmationPhrase = ""
    @State private var validationErrors: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal & Dose") {
                    HStack {
                        Text("Total insulin")
                        Spacer()
                        TextField(
                            "Units",
                            value: $totalUnits,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    }

                    HStack {
                        Text("Carbohydrates")
                        Spacer()
                        TextField(
                            "Grams",
                            value: $carbsGrams,
                            format: .number.precision(.fractionLength(0...0))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    }
                }

                Section("Delivery") {
                    Picker("Delivery pattern", selection: $distribution) {
                        ForEach(ExtendedBolusDistribution.allCases) { pattern in
                            Text(pattern.rawValue)
                                .tag(pattern)
                        }
                    }

                    if distribution != .immediate {
                        Picker("Duration", selection: $durationHours) {
                            ForEach([1, 2, 3, 4], id: \.self) { hours in
                                Text("\(hours) hour\(hours == 1 ? "" : "s")")
                                    .tag(hours)
                            }
                        }
                    }

                    if !plannedSegments.isEmpty {
                        ForEach(plannedSegments) { segment in
                            HStack {
                                Text(segment.scheduledAt.formatted(date: .omitted, time: .shortened))
                                Spacer()
                                Text(String(format: "%.2f U", segment.units))
                                    .font(.callout.monospaced())
                            }
                        }
                    }
                }

                Section("Safety Check") {
                    LabeledContent("Current glucose", value: currentGlucoseText)
                    LabeledContent("Reading age", value: readingAgeText)
                    LabeledContent("Insulin on board", value: String(format: "%.2f U", store.pumpStatus.iobUnits))

                    SecureField("Type CONFIRM BOLUS", text: $confirmationPhrase)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                if !validationErrors.isEmpty {
                    Section("Blocked") {
                        ForEach(validationErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Button {
                        createRequest()
                    } label: {
                        Text("Create Bolus Plan")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .disabled(totalUnits <= 0)

                    Button(role: .destructive) {
                        bolusService.cancelFutureSegments()
                    } label: {
                        Text("Cancel Future Segments")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(bolusService.activeSegments.isEmpty)
                } footer: {
                    Text("This creates a local bolus plan and safety record. It does not remotely command the Tandem t:slim X2. Confirm and deliver the bolus on the pump itself.")
                }

                if !bolusService.activeSegments.isEmpty {
                    Section("Active Bolus Plan") {
                        ForEach(bolusService.activeSegments) { segment in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(segment.scheduledAt.formatted(date: .omitted, time: .shortened))
                                    Text(segment.status.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(String(format: "%.2f U", segment.units))
                                    .font(.callout.monospaced())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bolus Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var currentGlucoseText: String {
        guard let latest = store.latestReading else { return "Unavailable" }
        return store.formatGlucose(latest.mgdL)
    }

    private var readingAgeText: String {
        guard let latest = store.latestReading else { return "Unavailable" }
        let minutes = Int(Date.now.timeIntervalSince(latest.timestamp) / 60)
        return minutes <= 0 ? "Just now" : "\(minutes)m ago"
    }

    private var plannedSegments: [BolusSegment] {
        guard totalUnits > 0 else { return [] }

        var planned: [BolusSegment] = []
        let start = Date.now

        switch distribution {
        case .immediate:
            planned.append(
                BolusSegment(
                    id: UUID(),
                    scheduledAt: start,
                    units: totalUnits.roundedToPumpIncrement(),
                    status: .pending
                )
            )

        case .even:
            let increments = durationHours * 2
            let units = (totalUnits / Double(increments)).roundedToPumpIncrement()

            for index in 0..<increments {
                planned.append(
                    BolusSegment(
                        id: UUID(),
                        scheduledAt: start.addingTimeInterval(Double(index * 1800)),
                        units: units,
                        status: .pending
                    )
                )
            }

        case .frontLoaded:
            let immediate = (totalUnits * 0.5).roundedToPumpIncrement()
            let remaining = max(0, totalUnits - immediate)
            let increments = max(1, durationHours * 2 - 1)
            let units = (remaining / Double(increments)).roundedToPumpIncrement()

            planned.append(
                BolusSegment(id: UUID(), scheduledAt: start, units: immediate, status: .pending)
            )

            for index in 1...increments {
                planned.append(
                    BolusSegment(
                        id: UUID(),
                        scheduledAt: start.addingTimeInterval(Double(index * 1800)),
                        units: units,
                        status: .pending
                    )
                )
            }
        }

        return planned
    }

    private func createRequest() {
        let created = bolusService.createBolus(
            totalUnits: totalUnits,
            durationHours: durationHours,
            distribution: distribution,
            glucoseMmolL: store.latestReading?.mmolL,
            glucoseTimestamp: store.latestReading?.timestamp,
            insulinOnBoardUnits: store.pumpStatus.iobUnits,
            carbsGrams: carbsGrams,
            confirmationPhrase: confirmationPhrase
        )

        validationErrors = created ? [] : bolusService.validationErrors(
            requestedUnits: totalUnits,
            glucoseMmolL: store.latestReading?.mmolL,
            glucoseTimestamp: store.latestReading?.timestamp,
            insulinOnBoardUnits: store.pumpStatus.iobUnits,
            confirmationPhrase: confirmationPhrase
        )

        if created {
            confirmationPhrase = ""
        }
    }
}

private extension Double {
    func roundedToPumpIncrement() -> Double {
        (self * 100).rounded() / 100
    }
}