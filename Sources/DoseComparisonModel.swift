import Foundation

struct DoseComparisonModel {
    struct Sample {
        let at: Date
        let withoutDose: Double
        let withDose: Double
    }

    let now: Date
    let assumedAt: Date
    let start: Date
    let end: Date
    let samples: [Sample]
    let actualDoses: [Dose]
    let assumedDose: Dose
    let upperLevel: Double
    let curve: PlasmaCurveConfiguration

    init(doses: [Dose], mg: Int, now: Date, assumedAt: Date? = nil,
         curve: PlasmaCurveConfiguration = .standard) {
        self.now = now
        self.curve = curve
        let historyLimit = now.addingTimeInterval(-72 * 3600)
        let actual = doses.filter { $0.at <= now && $0.at.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.at < $1.at }
        let requestedAt = assumedAt ?? now
        let scheduledAt = requestedAt.timeIntervalSinceReferenceDate.isFinite ? max(now, requestedAt) : now
        self.assumedAt = scheduledAt
        let assumed = Dose(at: scheduledAt, mg: mg)

        let earliest = actual.map(\.at).min()
        let proposedStart = earliest?.addingTimeInterval(-3600) ?? now.addingTimeInterval(-16 * 3600)
        let startDate = max(historyLimit, min(now.addingTimeInterval(-4 * 3600), proposedStart))
        let endDate = scheduledAt.addingTimeInterval(12 * 3600)

        let sampleValues = Self.makeSamples(actual: actual, assumed: assumed, curve: curve,
                                            range: startDate...endDate, now: now, count: 240)
        actualDoses = actual
        assumedDose = assumed
        start = startDate
        end = endDate
        samples = sampleValues
        upperLevel = max(1.15, (sampleValues.map(\.withDose).max() ?? 0) * 1.12)
    }

    func levels(after interval: TimeInterval) -> (withoutDose: Double, withDose: Double) {
        levels(at: now.addingTimeInterval(interval))
    }

    func levels(at: Date) -> (withoutDose: Double, withDose: Double) {
        return (DoseEngine.totalPlasma(actualDoses, at: at, curve: curve),
                DoseEngine.totalPlasma(actualDoses + [assumedDose], at: at, curve: curve))
    }

    /// Zooming resamples both scenarios over the visible window using the same model.
    func samples(in range: ClosedRange<Date>, count: Int = 320) -> [Sample] {
        Self.makeSamples(actual: actualDoses, assumed: assumedDose, curve: curve,
                         range: range, now: now, count: count)
    }

    private static func makeSamples(actual: [Dose], assumed: Dose,
                                    curve: PlasmaCurveConfiguration,
                                    range: ClosedRange<Date>, now: Date, count: Int) -> [Sample] {
        let span = max(0.001, range.upperBound.timeIntervalSince(range.lowerBound))
        let steps = max(2, min(600, count))
        var dates = (0...steps).map {
            range.lowerBound.addingTimeInterval(span * Double($0) / Double(steps))
        }
        if range.contains(now) { dates.append(now) }
        let simulated = actual + [assumed]
        for dose in simulated {
            let absorption = dose.at.addingTimeInterval(curve.lag(for: dose.food) * 3600)
            let foodShift = dose.food == .withFood ? PlasmaCurveConfiguration.foodDelayHours : 0
            let peak = dose.at.addingTimeInterval((curve.peakTimeHours + foodShift) * 3600)
            // Preserve the decay shape even when the uniform grid spans weeks or years.
            let decayDates = [1.0, 2, 4, 8, 16].map {
                peak.addingTimeInterval($0 * curve.halfLifeHours * 3600)
            }
            dates.append(contentsOf: decayDates.filter { range.contains($0) })
            dates.append(contentsOf: [dose.at, absorption, peak].filter { range.contains($0) })
        }
        return Array(Set(dates)).sorted().map { date in
            Sample(at: date,
                   withoutDose: DoseEngine.totalPlasma(actual, at: date, curve: curve),
                   withDose: DoseEngine.totalPlasma(simulated, at: date, curve: curve))
        }
    }

}

