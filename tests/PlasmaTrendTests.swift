import Foundation

@main struct PlasmaTrendTests {
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }

    static func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-8) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
    }

    // Independent numerical derivative of the production concentration curve.
    // Check away from the absorption kink, where a two-sided derivative exists.
    static func finiteDifference(_ doses: [Dose], at date: Date,
                                 curve: PlasmaCurveConfiguration) -> Double {
        let step = 0.25
        let before = DoseEngine.totalPlasma(doses, at: date.addingTimeInterval(-step), curve: curve)
        let after = DoseEngine.totalPlasma(doses, at: date.addingTimeInterval(step), curve: curve)
        return (after - before) * 3600 / (2 * step)
    }

    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func dose(hoursAgo: Double, mg: Int = 50, food: FoodState = .unknown) -> Dose {
            Dose(at: now.addingTimeInterval(-hoursAgo * 3600), mg: mg, food: food)
        }

        check(PlasmaTrend.slope(doses: [], at: now) == 0, "empty history is level")
        check(PlasmaTrend.slope(doses: [dose(hoursAgo: 0.2)], at: now) == 0,
              "absorption lag is level")
        let rise = PlasmaTrend.slope(doses: [dose(hoursAgo: 1)], at: now)
        let fall = PlasmaTrend.slope(doses: [dose(hoursAgo: 10)], at: now)
        check(rise > 0 && fall < 0, "absorption rises and elimination falls")
        check(close(PlasmaTrend.slope(doses: [dose(hoursAgo: 3.8)], at: now), 0),
              "single-dose model peak is level")
        check(PlasmaTrend.slope(doses: [dose(hoursAgo: 1, food: .withFood)], at: now) == 0,
              "food preserves its longer absorption delay")
        check(close(PlasmaTrend.slope(doses: [dose(hoursAgo: 1.9, food: .withFood)], at: now), rise),
              "food shifts the same slope by 0.9 hours")

        let mixed = [dose(hoursAgo: 1, mg: 25), dose(hoursAgo: 10, mg: 100)]
        let mixedSlope = PlasmaTrend.slope(doses: mixed, at: now)
        check(close(mixedSlope, rise * 0.5 + fall * 2),
              "overlapping doses retain opposing slopes and dose weights")
        let recentWaiting = dose(hoursAgo: 0.1)
        check(PlasmaTrend.slope(doses: [dose(hoursAgo: 10), recentWaiting], at: now) < 0,
              "a new dose in lag does not incorrectly turn a declining total upward")
        let future = dose(hoursAgo: -2)
        check(close(PlasmaTrend.slope(doses: mixed + [future], at: now), mixedSlope),
              "future records do not alter the current derivative")
        check(PlasmaTrend.slope(doses: [dose(hoursAgo: 1, mg: 0), dose(hoursAgo: 1, mg: -50)], at: now) == 0,
              "nonpositive doses contribute no trend")
        let ancient = Dose(at: now.addingTimeInterval(-1e12), mg: 50)
        check(PlasmaTrend.slope(doses: [ancient], at: now).isFinite,
              "remote history remains finite after exponential underflow")

        let halfLife = 2.0
        let equalRates = PlasmaCurveConfiguration(peakTimeHours: 0.5 + halfLife / log(2),
                                                  halfLifeHours: halfLife)
        let slowAbsorption = PlasmaCurveConfiguration(peakTimeHours: 30, halfLifeHours: 2)
        check(abs(equalRates.absorptionRate - equalRates.eliminationRate)
              < equalRates.eliminationRate * 1e-8, "fixture exercises the equal-rate limit")
        check(slowAbsorption.absorptionRate < slowAbsorption.eliminationRate,
              "fixture exercises absorption slower than elimination")
        let curves: [PlasmaCurveConfiguration] = [
            .standard,
            PlasmaCurveConfiguration(peakTimeHours: 4.5, halfLifeHours: 12),
            equalRates,
            slowAbsorption
        ]
        for (index, curve) in curves.enumerated() {
            for age in [0.2, 0.75, 2.0, 5.0, 12.0, 40.0] {
                for food in [FoodState.unknown, .withFood] {
                    let history = [dose(hoursAgo: age, mg: 75, food: food), dose(hoursAgo: 18, mg: 25)]
                    let analytic = PlasmaTrend.slope(doses: history, at: now, curve: curve)
                    let numeric = finiteDifference(history, at: now, curve: curve)
                    check(close(analytic, numeric, tolerance: 2e-7),
                          "curve \(index), age \(age), food \(food): derivative matches concentration finite difference")
                }
            }
            check(close(PlasmaTrend.slope(doses: [dose(hoursAgo: curve.peakTimeHours)], at: now, curve: curve), 0),
                  "custom model \(index) has a horizontal peak")
        }

        check(PlasmaTrend.angleDegrees(slope: 0) == 0, "zero slope points right")
        check(close(PlasmaTrend.angleDegrees(slope: 1), -45)
              && close(PlasmaTrend.angleDegrees(slope: -1), 45),
              "one relative level per hour maps to a signed 45-degree angle")
        let angles = [-100.0, -1, -0.5, -0.001, 0, 0.001, 0.5, 1, 100]
            .map { PlasmaTrend.angleDegrees(slope: $0) }
        check(zip(angles, angles.dropFirst()).allSatisfy { $0 > $1 },
              "angle varies strictly with magnitude, with no fixed directional buckets")
        check(angles.allSatisfy { $0.isFinite && abs($0) < 90 },
              "finite slopes retain rightward-facing finite angles")
        check(abs(PlasmaTrend.angleDegrees(slope: 0.001)) < 0.1,
              "a nearly level curve remains nearly horizontal")
        check(abs(PlasmaTrend.angleDegrees(slope: 0.5001)
                  - PlasmaTrend.angleDegrees(slope: 0.5)) < 0.01,
              "small slope changes produce continuous angle changes")
        print("PASS: \(passed) plasma trend regression checks")
    }
}
