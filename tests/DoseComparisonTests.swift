import Foundation

@main struct DoseComparisonTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        guard value() else { fatalError("FAIL: " + description) }
        passed += 1
    }
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-10 }

    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let historical = Dose(at: now.addingTimeInterval(-30 * 24 * 3600), mg: 50)
        let recent = Dose(at: now.addingTimeInterval(-2 * 3600), mg: 50)
        let records = [historical, recent]
        let original = records
        let scheduled = now.addingTimeInterval(48 * 3600)
        let model = DoseComparisonModel(doses: records, mg: 50, now: now, assumedAt: scheduled)
        check(model.assumedAt == scheduled && model.now == now, "hypothetical time differs from reference now")
        check(model.end >= scheduled.addingTimeInterval(12 * 3600), "initial domain includes hypothetical future tail")
        check(model.actualDoses == original && records == original, "simulation leaves actual records unchanged")
        for date in [historical.at, now, scheduled.addingTimeInterval(-1), scheduled, scheduled.addingTimeInterval(29 * 60)] {
            let values = model.levels(at: date)
            check(values.withDose == values.withoutDose, "scenarios equal before absorption at \(date)")
        }
        let peakDate = scheduled.addingTimeInterval(PlasmaCurveConfiguration.standard.peakTimeHours * 3600)
        let peak = model.levels(at: peakDate)
        check(close(peak.withDose - peak.withoutDose, 1), "50 mg contribution peaks at shifted dose time")
        let originalTimeModel = DoseComparisonModel(doses: records, mg: 50, now: now)
        let originalPeak = originalTimeModel.levels(at: now.addingTimeInterval(3.8 * 3600))
        check(close(originalPeak.withDose - originalPeak.withoutDose, peak.withDose - peak.withoutDose), "moving hypothetical time preserves its peak magnitude")
        check(model.levels(after: 2 * 3600).withDose == model.levels(at: now.addingTimeInterval(2 * 3600)).withDose, "relative inspection remains anchored to now")
        let historyRange = historical.at.addingTimeInterval(-3600)...historical.at.addingTimeInterval(12 * 3600)
        let history = model.samples(in: historyRange)
        check(history.first?.at == historyRange.lowerBound && history.last?.at == historyRange.upperBound, "past resampling exceeds initial 72-hour viewport")
        check((history.map(\.withoutDose).max() ?? 0) > 0.99, "old actual records remain available when panning backwards")
        check(history.allSatisfy { $0.withDose == $0.withoutDose }, "historical chart excludes later hypothetical contribution")
        let veryBroadRange = historical.at.addingTimeInterval(-365 * 24 * 3600)...now.addingTimeInterval(365 * 24 * 3600)
        let broadComparison = model.samples(in: veryBroadRange, count: 2)
        let broadHome = DoseCurveModel(doses: records, now: now).samples(in: veryBroadRange, count: 2)
        let historicalPeak = historical.at.addingTimeInterval(3.8 * 3600)
        for halfLives in [1.0, 2, 4, 8, 16] {
            let tailAt = historicalPeak.addingTimeInterval(halfLives * 10.7 * 3600)
            let expected = DoseEngine.totalPlasma(records, at: tailAt)
            check(broadComparison.contains { $0.at == tailAt && close($0.withoutDose, expected) },
                  "broad simulation preserves decay landmark at \(halfLives) half-lives")
            check(broadHome.contains { $0.at == tailAt && close($0.level, expected) },
                  "broad home chart preserves decay landmark at \(halfLives) half-lives")
        }
        let distant = now.addingTimeInterval(365 * 24 * 3600)
        let futureRange = distant...distant.addingTimeInterval(24 * 3600)
        let future = model.samples(in: futureRange)
        check(future.first?.at == futureRange.lowerBound && future.last?.at == futureRange.upperBound, "future resampling is not clamped to preview range")
        check(future.allSatisfy { $0.withDose.isFinite && $0.withoutDose.isFinite }, "distant future samples remain finite")
        let distantModel = DoseComparisonModel(doses: records, mg: 50, now: now, assumedAt: distant)
        check(close(distantModel.levels(at: distant.addingTimeInterval(3.8 * 3600)).withDose, 1), "hypothetical dose can move a year into future")
        let custom = PlasmaCurveConfiguration(peakTimeHours: 4.5, halfLifeHours: 12)
        let configured = DoseComparisonModel(doses: records, mg: 50, now: now, assumedAt: scheduled, curve: custom)
        let sampleRange = scheduled...scheduled.addingTimeInterval(8 * 3600)
        check(configured.samples(in: sampleRange).allSatisfy { sample in
            close(sample.withoutDose, DoseEngine.totalPlasma(records, at: sample.at, curve: custom)) &&
            close(sample.withDose, DoseEngine.totalPlasma(records + [configured.assumedDose], at: sample.at, curve: custom))
        }, "comparison respects existing physical configuration at every sample")
        let clamped = DoseComparisonModel(doses: records, mg: 50, now: now, assumedAt: now.addingTimeInterval(-3600))
        check(clamped.assumedAt == now, "hypothetical edits cannot silently rewrite the past")
        let futureRecord = Dose(at: distant, mg: 50)
        check(DoseComparisonModel(doses: records + [futureRecord], mg: 50, now: now).actualDoses == records, "misdated future actual records do not contaminate predictions")
        print("PASS: \(passed) comparison simulation regression checks")
    }
}
