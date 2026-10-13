import Foundation

@main struct DoseCurveTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }
    static func close(_ a: Double, _ b: Double, tolerance: Double = 1e-12) -> Bool { abs(a - b) < tolerance }

    static func main() {
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-09-23T07:12:00+10:00")!
        let first = Dose(at: iso.date(from: "2026-09-21T08:00:00+10:00")!, mg: 40)
        let second = Dose(at: iso.date(from: "2026-09-21T16:26:00+10:00")!, mg: 40)
        let doses = [first, second]
        let curve = DoseCurveModel(doses: doses, now: now)
        check(curve.start < now && now < curve.end, "screenshot now is strictly inside the chart")
        check(curve.start <= first.at && curve.visibleDoses.count == 2, "both screenshot doses are visible")
        // Independently evaluated with 50-digit decimal arithmetic for the current
        // 3.8 h peak / 10.7 h half-life defaults; the old fixture used fixed ka/ke.
        check(close(curve.currentLevel, 0.1775962657463119), "fixture current level matches current standard parameters")
        check(DoseCurveModel.levelText(curve.currentLevel) == "0.18 倍", "screenshot label rounds consistently")
        check(curve.samples.filter { $0.at == now }.count == 1, "now is sampled exactly once")
        check(curve.samples.first(where: { $0.at == now })!.level == curve.currentLevel,
              "now point and value share the exact same number")
        check(curve.currentLevel == DoseEngine.totalPlasma(doses, at: now), "chart uses the current model value")
        check(curve.currentLevel == DoseStatus.compute(doses: doses, now: now).plasmaTotal,
              "shared status and chart agree")
        check(curve.axisDates.first == curve.start && curve.axisDates.last == curve.end,
              "axis dates are real chart endpoints")
        check(close(curve.fraction(at: curve.start), 0) && close(curve.fraction(at: curve.end), 1),
              "date coordinates map to the chart bounds")

        let cutoff = first.at.addingTimeInterval(48 * 3600)
        let before = DoseEngine.totalPlasma([first], at: cutoff.addingTimeInterval(-1))
        let at = DoseEngine.totalPlasma([first], at: cutoff)
        let after = DoseEngine.totalPlasma([first], at: cutoff.addingTimeInterval(1))
        check(before > at && at > after && after > 0.05, "48 hours is no longer a zero cutoff")
        check(abs(before - after) < 0.00001, "48-hour boundary decays continuously")
        check(DoseStatus.compute(doses: [first], now: cutoff).plasmaTotal == at,
              "status retains contributions at and beyond 48 hours")
        let muchLater = first.at.addingTimeInterval(90 * 3600)
        let longTail = DoseCurveModel(doses: [first], now: muchLater)
        check(longTail.visibleDoses.isEmpty && longTail.currentLevel > 0,
              "dose outside the visible window still contributes naturally")
        check(longTail.upperLevel >= 1.15, "small residuals retain the 1.0 axis reference")
        check(DoseEngine.plasmaLevel(hoursSinceDose: 1e12).isFinite &&
              DoseEngine.plasmaLevel(hoursSinceDose: .infinity) == 0,
              "very old and non-finite times do not overflow")

        let trial = Dose(at: now, mg: 40)
        let hypothetical = doses + [trial]
        let preview = DoseCurveModel(doses: hypothetical, now: now, hypotheticalDoseID: trial.id)
        check(preview.visibleDoses.contains(where: { $0.id == trial.id }), "trial dose marker remains in view")
        check(preview.fraction(at: trial.at) > 0 && preview.fraction(at: trial.at) < 1,
              "trial marker is inside the visible window")
        check(preview.currentLevel == curve.currentLevel, "a dose at now has no instant concentration jump")
        let peak = DoseEngine.upcomingPlasmaPeak(hypothetical, from: now)!
        check(peak.at > now && peak.at < preview.end && peak.level > 1,
              "trial's future peak appears in the chart")
        let drop = DoseEngine.plasmaDropTime(hypothetical, to: 0.2, from: now)!
        check(drop > peak.at, "trial receding-to-0.2 time is after its peak, never now during absorption lag")
        check(DoseEngine.totalPlasma(hypothetical, at: drop) < 0.2 &&
              DoseEngine.totalPlasma(hypothetical, at: drop.addingTimeInterval(-300)) >= 0.2,
              "drop time is the first sampled descending crossing")
        check(DoseEngine.plasmaDropTime(doses, to: 0.2, from: now) == now,
              "already descending below threshold remains below without the trial")

        let empty = DoseCurveModel(doses: [], now: now)
        check(empty.start < now && empty.end > now && empty.currentLevel == 0,
              "empty records produce a valid zero-valued window")
        check(empty.samples.allSatisfy { $0.level == 0 && $0.level.isFinite }, "empty samples are finite")
        let future = Dose(at: now.addingTimeInterval(365 * 24 * 3600), mg: 40)
        let withFuture = DoseCurveModel(doses: doses + [future], now: now)
        check(withFuture.start == curve.start && withFuture.end == curve.end &&
              withFuture.samples.map(\.level) == curve.samples.map(\.level),
              "misdated future records do not stretch or change current predictions")
        let withFood = Dose(at: now, mg: 40, food: .withFood)
        let fed = DoseCurveModel(doses: [withFood], now: now)
        check(fed.samples.contains { $0.at == now.addingTimeInterval(1.4 * 3600) && $0.level < 1e-10 },
              "food-related absorption delay is preserved")
        check(PlasmaCurveConfiguration.standard.peakTimeHours == 3.8 &&
              PlasmaCurveConfiguration.standard.halfLifeHours == 10.7 && DoseEngine.plasmaLag == 0.5,
              "current standard curve configuration is preserved")
        let custom = PlasmaCurveConfiguration(peakTimeHours: 4.5, halfLifeHours: 12)
        let customCurve = DoseCurveModel(doses: doses, now: now, curve: custom)
        let inspectAt = first.at.addingTimeInterval(6.25 * 3600 + 17)
        check(customCurve.level(at: inspectAt) == DoseEngine.totalPlasma(doses, at: inspectAt, curve: custom),
              "inspection evaluates the exact selected time using the saved curve parameters")
        check(customCurve.level(at: inspectAt) != customCurve.currentLevel,
              "historical inspection does not reuse the fixed current value")
        let minuteRange = inspectAt...inspectAt.addingTimeInterval(60)
        let zoomed = customCurve.samples(in: minuteRange, count: 240)
        check(zoomed.first?.at == minuteRange.lowerBound && zoomed.last?.at == minuteRange.upperBound,
              "one-minute zoom preserves exact time bounds")
        check(zoomed.allSatisfy { $0.level == customCurve.level(at: $0.at) },
              "zoomed curve and inspection values use the same model")
        // Navigation must not stop at the default 72-hour history / 12-hour future view.
        let baseDuration = curve.end.timeIntervalSince(curve.start)
        let wideRange = CurveTimeViewport.range(baseStart: curve.start, baseEnd: curve.end,
                                                zoom: 0.25, offset: 0)
        check(close(wideRange.upperBound.timeIntervalSince(wideRange.lowerBound), baseDuration * 4),
              "zoom out below 1 expands beyond the initial range")
        for direction in [-1.0, 1.0] {
            let offset = direction * 365 * 24 * 3600
            let shifted = CurveTimeViewport.range(baseStart: curve.start, baseEnd: curve.end,
                                                   zoom: 1, offset: offset)
            check(close(shifted.lowerBound.timeIntervalSince(curve.start), offset),
                  "panning one year in either direction has no initial-window clamp")
        }
        let oldest = Dose(at: now.addingTimeInterval(-365 * 24 * 3600), mg: 80)
        let fullHistory = DoseCurveModel(doses: doses + [oldest], now: now)
        let oldPeakDate = oldest.at.addingTimeInterval(3.8 * 3600)
        let oldRange = oldest.at.addingTimeInterval(-3600)...oldest.at.addingTimeInterval(24 * 3600)
        check(close(fullHistory.level(at: oldPeakDate), 2, tolerance: 0.001),
              "historical inspection retains a dose one year before now")
        check(fullHistory.samples(in: oldRange).contains { $0.at == oldPeakDate && $0.level > 1.99 },
              "panned historical samples preserve the older dose peak")
        let enormousRange = now.addingTimeInterval(-10 * 365 * 24 * 3600)...now.addingTimeInterval(10 * 365 * 24 * 3600)
        let wideSamples = fullHistory.samples(in: enormousRange)
        check(wideSamples.contains { $0.at == oldPeakDate && $0.level > 1.99 },
              "wide zoom retains exact narrow peak dates")
        check(wideSamples.allSatisfy { $0.level.isFinite } && wideSamples.last!.level < 0.01,
              "remote future decays naturally with finite samples")
        let minimumRange = CurveTimeViewport.range(baseStart: curve.start, baseEnd: curve.end,
                                                   zoom: 1e15, offset: 0)
        check(close(minimumRange.upperBound.timeIntervalSince(minimumRange.lowerBound), 60),
              "maximum zoom keeps one minute inspectable")
        check(CurveTimeViewport.resolvedZoom(.nan, baseDuration: baseDuration).isFinite &&
              CurveTimeViewport.boundedOffset(.infinity).isFinite,
              "invalid gesture arithmetic cannot poison viewport state")
        print("PASS: \(passed) concentration curve regression checks; fixture now = \(curve.currentLevel)")
    }
}
