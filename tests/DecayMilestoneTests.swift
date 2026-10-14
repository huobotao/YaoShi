import Foundation

@main struct DecayMilestoneTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        passed += 1
    }
    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func dose(_ age: Double, mg: Int = 50, food: FoodState = .unknown) -> Dose {
            Dose(at: now.addingTimeInterval(-age * 3600), mg: mg, food: food)
        }
        func milestones(_ history: [Dose], _ curve: PlasmaCurveConfiguration = .standard) -> [PlasmaDecayMilestone] {
            DoseEngine.decayMilestones(history, from: now, curve: curve)
        }
        func verifyCrossings(_ history: [Dose], _ curve: PlasmaCurveConfiguration = .standard) {
            for row in milestones(history, curve) where !row.alreadyBelow {
                guard let at = row.at else { fatalError("Unexpected unresolved crossing") }
                check(DoseEngine.totalPlasma(history, at: at, curve: curve) <= row.target + 1e-8,
                      "returned crossing is on below-target side")
                check(DoseEngine.totalPlasma(history, at: at.addingTimeInterval(-1), curve: curve) >= row.target - 1e-8,
                      "crossing precision better than one second")
                for hours in [0.1, 1, 4, 12, 48, 168] {
                    check(DoseEngine.totalPlasma(history, at: at.addingTimeInterval(hours * 3600), curve: curve) < row.target,
                          "target remains below after final crossing")
                }
            }
        }
        check(milestones([]).isEmpty, "empty history has no milestone estimates")
        check(milestones([dose(-1)]).isEmpty, "future-only history has no estimates")
        let declining = [dose(8, mg: 250)]
        let baseline = milestones(declining)
        check(baseline.map(\.target) == [3, 2.5, 2, 1, 0.5, 0.1], "requested targets in descending order")
        let withFuture = milestones(declining + [dose(-10, mg: 250)])
        check(zip(baseline, withFuture).allSatisfy { $0.at == $1.at && $0.alreadyBelow == $1.alreadyBelow },
              "future dosing is excluded from no-further-dose estimate")
        check(baseline.last!.at!.timeIntervalSince(now) > 48 * 3600,
              "low threshold resolves beyond previous 48-hour horizon")
        check(zip(baseline, baseline.dropFirst()).allSatisfy { $0.at! < $1.at! },
              "lower targets have later crossings")
        verifyCrossings(declining)

        let old = milestones([dose(200)])
        check(old.allSatisfy { $0.alreadyBelow && $0.at == now }, "old residual is already below all thresholds")
        let waiting = [dose(0, mg: 200, food: .withFood)]
        check(DoseEngine.totalPlasma(waiting, at: now) == 0, "delayed fixture starts at zero")
        check(milestones(waiting).allSatisfy { !$0.alreadyBelow && $0.at! > now },
              "unabsorbed doses are not marked already below")
        verifyCrossings(waiting)
        let onePillPeak = milestones([dose(0)]).first { $0.target == 1 }!
        check(!onePillPeak.alreadyBelow && abs(onePillPeak.at!.timeIntervalSince(now) - 3.8 * 3600) < 1,
              "exact peak threshold returns upcoming peak, not already below")
        let fasted = milestones([dose(0, mg: 200)])
        let fed = milestones(waiting)
        check(zip(fasted, fed).allSatisfy { abs($1.at!.timeIntervalSince($0.at!) - 0.9 * 3600) < 0.5 },
              "food delay shifts every crossing by 0.9 hours")

        // Initially declining above 1, briefly drops below 1, then a recorded but unabsorbed
        // dose lifts it above 1 again. The final descent must win over the first descent.
        let rebound = [dose(5), dose(0, mg: 50, food: .withFood)]
        let one = milestones(rebound).first { $0.target == 1 }!
        check(!one.alreadyBelow && one.at!.timeIntervalSince(now) > 5 * 3600,
              "pending absorption chooses later descent instead of temporary dip")
        verifyCrossings(rebound)

        let curves = [
            PlasmaCurveConfiguration(peakTimeHours: 4.5, halfLifeHours: 15),
            PlasmaCurveConfiguration(peakTimeHours: 0.5 + 2 / log(2), halfLifeHours: 2),
            PlasmaCurveConfiguration(peakTimeHours: 10, halfLifeHours: 3)
        ]
        for curve in curves {
            verifyCrossings([dose(0.1, mg: 150), dose(8, mg: 100, food: .withFood)], curve)
        }
        check(milestones(declining, curves[0]).last!.at! > baseline.last!.at!,
              "longer configured half-life delays low-level milestone")
        let slow = PlasmaCurveConfiguration(peakTimeHours: 20, halfLifeHours: 200)
        check(milestones([dose(0, mg: 250)], slow).last!.at!.timeIntervalSince(now) > 30 * 24 * 3600,
              "adaptive horizon also supports custom tails longer than 30 days")
        verifyCrossings([dose(0, mg: 250)], slow)
        print("PASS: \(passed) decay milestone regression checks")
    }
}
