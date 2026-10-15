import Foundation

@main enum WatchCurveSamplingTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let doses = [
            Dose(at: now.addingTimeInterval(-9 * 3600), mg: 50),
            Dose(at: now.addingTimeInterval(-4 * 3600), mg: 50),
            Dose(at: now.addingTimeInterval(-35 * 60), mg: 50)
        ]
        let model = DoseCurveModel(doses: doses, now: now)
        let keyDates = model.visibleDoses.flatMap { dose in
            [dose.at,
             dose.at.addingTimeInterval(model.curve.lag(for: dose.food) * 3600),
             dose.at.addingTimeInterval(model.curve.peakTimeHours * 3600)]
        }
        let samples = WatchCurveSampling.samples(start: model.start, end: model.end,
            now: now, keyDates: keyDates, levelAt: model.level(at:))
        let snapshot = WatchCurveSnapshot(start: model.start, end: model.end, now: now,
            currentLevel: model.currentLevel, upperLevel: model.upperLevel,
            samples: samples, doses: [])
        precondition(samples.count < 500, "Wire curve stays bounded")
        precondition(WatchCurveMath.level(in: snapshot, at: now) == model.currentLevel,
                     "Watch current readout equals phone model exactly at snapshot time")
        var worstError = 0.0
        for minute in stride(from: -240, through: 720, by: 1) {
            let at = now.addingTimeInterval(Double(minute) * 60)
            let interpolated = WatchCurveMath.level(in: snapshot, at: at)!
            worstError = max(worstError, abs(interpolated - model.level(at: at)))
        }
        precondition(worstError < 0.005, "Watch estimate should round to the same two-decimal readout near now; max error \(worstError)")
        precondition(WatchCurveMath.level(in: snapshot, at: model.end.addingTimeInterval(1)) == nil,
                     "Expired forecasts never keep showing a numeric result")
        print("Watch curve sampling passed; worst 16-hour interpolation error \(worstError)")
    }
}
