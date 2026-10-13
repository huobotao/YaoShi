import Foundation

enum DoseAverageDirection: String, CaseIterable {
    case backward, forward, centered

    var label: String {
        switch self {
        case .backward: return "向前回看"
        case .forward: return "向后查看"
        case .centered: return "前后各半"
        }
    }
}

enum DoseAverageWindow: Int, CaseIterable {
    case day = 1, week = 7, fortnight = 14, fourWeeks = 28

    var label: String {
        switch self {
        case .day: return "24 小时"
        case .week: return "7 天"
        case .fortnight: return "2 周"
        case .fourWeeks: return "4 周"
        }
    }

    /// Fixed elapsed time, independent of daylight-saving or calendar-day lengths.
    var duration: TimeInterval { Double(rawValue) * 24 * 3600 }
}

struct DoseAverageSummary {
    let start: Date
    let end: Date
    /// Recorded pill counts take precedence; legacy milligrams use the current pill strength.
    /// Unavailable when hasValidPillStrength is false; the zero is only a storage placeholder.
    let totalPills: Double
    let estimatedDoseCount: Int
    let averagePer24Hours: Double?
    let recordCount: Int
    let containsFuture: Bool
    /// Evidence of historical span only; this cannot establish complete recording coverage.
    let hasRecordsBeforeWindow: Bool
    let hasValidPillStrength: Bool
    /// Invalid milligrams inside the elapsed window, plus records with unlocatable timestamps.
    let invalidDoseCount: Int

    /// Counts actual records in (start, end], additionally requiring at <= now and mg > 0.
    /// Coverage gaps never shorten the denominator. Windows reaching into the future have no average.
    init(doses: [Dose], anchor: Date, now: Date, window: DoseAverageWindow,
         direction: DoseAverageDirection, mgPerPill: Int) {
        let offset: TimeInterval
        switch direction {
        case .backward: offset = -window.duration
        case .forward: offset = 0
        case .centered: offset = -window.duration / 2
        }
        let startDate = anchor.addingTimeInterval(offset)
        let endDate = startDate.addingTimeInterval(window.duration)
        start = startDate
        end = endDate
        containsFuture = endDate > now
        hasValidPillStrength = mgPerPill > 0

        let datedRecords = doses.filter { $0.at.timeIntervalSinceReferenceDate.isFinite }
        let elapsedRecords = datedRecords.filter {
            $0.at > startDate && $0.at <= endDate && $0.at <= now
        }
        let validRecords = elapsedRecords.filter { $0.mg > 0 }
        recordCount = validRecords.count
        invalidDoseCount = doses.count - datedRecords.count + elapsedRecords.filter { $0.mg <= 0 }.count
        hasRecordsBeforeWindow = datedRecords.contains {
            $0.at <= startDate && $0.at <= now && $0.mg > 0
        }
        estimatedDoseCount = validRecords.filter { ($0.pillCount ?? 0) <= 0 }.count
        totalPills = validRecords.reduce(0.0) { total, dose in
            if let count = dose.pillCount, count > 0 { return total + Double(count) }
            return total + (mgPerPill > 0 ? Double(dose.mg) / Double(mgPerPill) : 0)
        }
        averagePer24Hours = !containsFuture && hasValidPillStrength
            ? totalPills / Double(window.rawValue)
            : nil
    }
}
