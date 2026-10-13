import Foundation

/// A movable, elapsed-time window of recorded doses. This does not infer missing records.
struct DoseWindowSummary {
    let start: Date
    let end: Date
    let durationHours: Double
    let referenceHours: Double
    let totalPills: Double
    let totalMg: Int
    let doseCount: Int
    let normalizedPills: Double
    let estimatedDoseCount: Int
    let recordedDoses: [Dose]

    init(doses: [Dose], end: Date, durationHours: Double,
         referenceHours: Double = 24, mgPerPill: Int, now: Date = Date()) {
        func validHours(_ hours: Double) -> Double {
            guard hours.isFinite, hours > 0 else { return 24 }
            return min(max(hours, 1), 8760)
        }
        self.durationHours = validHours(durationHours)
        self.referenceHours = validHours(referenceHours)
        let validNow = now.timeIntervalSince1970.isFinite ? now : Date()
        self.end = end.timeIntervalSince1970.isFinite ? min(end, validNow) : validNow
        start = self.end.addingTimeInterval(-self.durationHours * 3600)

        // Excluding the left endpoint makes adjacent windows non-overlapping.
        let windowStart = start
        let windowEnd = self.end
        recordedDoses = doses.filter {
            $0.at.timeIntervalSince1970.isFinite && $0.at > windowStart && $0.at <= windowEnd
        }.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at
        }
        doseCount = recordedDoses.count
        let strength = Double(max(mgPerPill, 1))
        var pills = 0.0
        var milligrams = 0
        var estimates = 0
        for dose in recordedDoses {
            let mg = max(dose.mg, 0)
            let sum = milligrams.addingReportingOverflow(mg)
            milligrams = sum.overflow ? Int.max : sum.partialValue
            if let count = dose.pillCount, count > 0 {
                pills += Double(count)
            } else {
                pills += Double(mg) / strength
                estimates += 1
            }
        }
        totalMg = milligrams
        totalPills = pills
        estimatedDoseCount = estimates
        normalizedPills = pills * self.referenceHours / self.durationHours
    }
}
