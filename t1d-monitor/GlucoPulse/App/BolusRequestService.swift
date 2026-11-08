import Foundation
import SwiftUI

enum ExtendedBolusDistribution: String, CaseIterable, Identifiable {
    case even = "Evenly spread"
    case frontLoaded = "50% now + spread"

    var id: String { rawValue }
}

struct BolusSegment: Identifiable, Codable {
    enum Status: String, Codable {
        case pending
        case delivered
        case cancelled
    }

    let id: UUID
    let scheduledAt: Date
    let units: Double
    var status: Status
}

struct BolusAuditEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let event: String
    let detail: String
}

@MainActor
final class BolusRequestService: ObservableObject {
    static let confirmationPhrase = "CONFIRM BOLUS"

    @Published private(set) var segments: [BolusSegment] = []
    @Published private(set) var auditLog: [BolusAuditEntry] = []

    private let defaults = UserDefaults.standard
    private let segmentsKey = "glucopulse.bolus.segments"
    private let auditKey = "glucopulse.bolus.audit"

    init() {
        load()
    }

    var activeSegments: [BolusSegment] {
        segments.filter { $0.status == .pending && $0.scheduledAt >= Date.now.addingTimeInterval(-300) }
    }

    func validationErrors(
        requestedUnits: Double,
        glucoseMmolL: Double?,
        glucoseTimestamp: Date?,
        insulinOnBoardUnits: Double,
        confirmationPhrase: String
    ) -> [String] {
        var errors: [String] = []
        let maxSingle = defaults.double(forKey: "glucopulse.bolus.maxSingleUnits")
        let maxIOB = defaults.double(forKey: "glucopulse.bolus.maxIOBUnits")
        let minimumGlucose = defaults.double(forKey: "glucopulse.bolus.minimumGlucoseMmolL")

        if requestedUnits <= 0 {
            errors.append("Enter a bolus dose greater than zero.")
        }

        if maxSingle > 0 && requestedUnits > maxSingle {
            errors.append("Requested dose exceeds the configured maximum of \(String(format: "%.1f", maxSingle)) U.")
        }

        if maxIOB > 0 && insulinOnBoardUnits + requestedUnits > maxIOB {
            errors.append("Requested dose plus IOB exceeds the configured safety limit of \(String(format: "%.1f", maxIOB)) U.")
        }

        guard let glucoseMmolL, let glucoseTimestamp else {
            errors.append("A current CGM reading is required.")
            return errors
        }

        let ageMinutes = Date.now.timeIntervalSince(glucoseTimestamp) / 60
        if ageMinutes > 10 {
            errors.append("CGM reading is older than 10 minutes. Take a fresh reading first.")
        }

        if glucoseMmolL < minimumGlucose {
            errors.append("Glucose is below \(String(format: "%.1f", minimumGlucose)) mmol/L. Treat hypoglycaemia first and do not bolus now.")
        }

        if confirmationPhrase != Self.confirmationPhrase {
            errors.append("Type \(Self.confirmationPhrase) exactly to confirm.")
        }

        return errors
    }

    func createExtendedBolus(
        totalUnits: Double,
        durationHours: Int,
        distribution: ExtendedBolusDistribution,
        glucoseMmolL: Double?,
        glucoseTimestamp: Date?,
        insulinOnBoardUnits: Double,
        carbsGrams: Double,
        confirmationPhrase: String
    ) -> Bool {
        let errors = validationErrors(
            requestedUnits: totalUnits,
            glucoseMmolL: glucoseMmolL,
            glucoseTimestamp: glucoseTimestamp,
            insulinOnBoardUnits: insulinOnBoardUnits,
            confirmationPhrase: confirmationPhrase
        )

        guard errors.isEmpty else {
            log("BLOCKED", errors.joined(separator: " "))
            return false
        }

        guard durationHours >= 1 && durationHours <= 4 else {
            log("BLOCKED", "Extended duration must be between 1 and 4 hours.")
            return false
        }

        var planned: [BolusSegment] = []
        let startDate = Date.now

        switch distribution {
        case .even:
            let increments = durationHours * 2
            let unitPerSegment = (totalUnits / Double(increments)).roundedToPumpIncrement()

            for index in 0..<increments {
                planned.append(
                    BolusSegment(
                        id: UUID(),
                        scheduledAt: startDate.addingTimeInterval(Double(index * 1800)),
                        units: unitPerSegment,
                        status: .pending
                    )
                )
            }

        case .frontLoaded:
            let immediateUnits = (totalUnits * 0.5).roundedToPumpIncrement()
            let remainingUnits = max(0, totalUnits - immediateUnits)
            let laterIncrements = max(1, durationHours * 2 - 1)
            let unitPerSegment = (remainingUnits / Double(laterIncrements)).roundedToPumpIncrement()

            planned.append(
                BolusSegment(id: UUID(), scheduledAt: startDate, units: immediateUnits, status: .pending)
            )

            for index in 1...laterIncrements {
                planned.append(
                    BolusSegment(
                        id: UUID(),
                        scheduledAt: startDate.addingTimeInterval(Double(index * 1800)),
                        units: unitPerSegment,
                        status: .pending
                    )
                )
            }
        }

        segments.append(contentsOf: planned)
        save()

        log(
            "REQUESTED",
            "\(String(format: "%.2f", totalUnits)) U over \(durationHours)h (\(distribution.rawValue)); carbs: \(String(format: "%.0f", carbsGrams)) g; glucose: \(glucoseMmolL.map { String(format: "%.1f", $0) } ?? "unavailable") mmol/L. Confirm and deliver each segment on the Tandem t:slim X2."
        )

        return true
    }

    func cancelFutureSegments() {
        let now = Date.now
        var changed = false

        for index in segments.indices
        where segments[index].status == .pending && segments[index].scheduledAt > now {
            segments[index].status = .cancelled
            changed = true
        }

        if changed {
            save()
            log("CANCELLED", "All future undelivered extended-bolus segments were cancelled.")
        }
    }

    func markSegmentDelivered(_ segment: BolusSegment) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        segments[index].status = .delivered
        save()
        log(
            "CONFIRMED ON PUMP",
            "\(String(format: "%.2f", segment.units)) U scheduled for \(segment.scheduledAt.formatted(date: .omitted, time: .shortened))."
        )
    }

    private func log(_ event: String, _ detail: String) {
        auditLog.insert(
            BolusAuditEntry(id: UUID(), timestamp: Date.now, event: event, detail: detail),
            at: 0
        )

        if auditLog.count > 200 {
            auditLog = Array(auditLog.prefix(200))
        }

        saveAudit()
    }

    private func load() {
        if let data = defaults.data(forKey: segmentsKey),
           let decoded = try? JSONDecoder().decode([BolusSegment].self, from: data) {
            segments = decoded
        }

        if let data = defaults.data(forKey: auditKey),
           let decoded = try? JSONDecoder().decode([BolusAuditEntry].self, from: data) {
            auditLog = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(segments) {
            defaults.set(data, forKey: segmentsKey)
        }
    }

    private func saveAudit() {
        if let data = try? JSONEncoder().encode(auditLog) {
            defaults.set(data, forKey: auditKey)
        }
    }
}

private extension Double {
    func roundedToPumpIncrement() -> Double {
        (self * 100).rounded() / 100
    }
}