import Foundation

@main
struct WatchCurveModelTests {
    static func main() {
        let doseAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dose = WatchDoseSummary(id: UUID(), at: doseAt, mg: 50, med: "Vyvanse")
        let beforeAbsorption = doseAt.addingTimeInterval(0.49 * 3600)
        let peak = doseAt.addingTimeInterval(3.8 * 3600)
        let later = doseAt.addingTimeInterval(20 * 3600)
        precondition(WatchCurveModel.level(doses: [dose], at: beforeAbsorption) == 0)
        precondition(abs(WatchCurveModel.level(doses: [dose], at: peak) - 1) < 1e-9)
        precondition(WatchCurveModel.level(doses: [dose], at: later) < 1)
        precondition(WatchCurveModel.level(doses: [dose, dose], at: peak) > 1.999)
        precondition(WatchCurveModel.points(doses: [dose], now: peak).count == 105)
        // Synthetic four-dose fixture: matches the R8 3.22x display format
        // without storing any real health record in the repository.
        let fixtureNow = doseAt.addingTimeInterval(24 * 3600)
        let ages: [Double] = [3, 4, 8, 18]
        let fixture = ages.map { age in
            WatchDoseSummary(id: UUID(), at: fixtureNow.addingTimeInterval(-age * 3600),
                             mg: 50, med: "Vyvanse")
        }
        precondition(String(format: "%.2f", WatchCurveModel.level(doses: fixture, at: fixtureNow)) == "3.22")
        precondition(WatchCurveModel.level(doses: [], at: fixtureNow) == 0)
        precondition(WatchCurveModel.isStale(generatedAt: nil, now: fixtureNow))
        precondition(!WatchCurveModel.isStale(generatedAt: fixtureNow.addingTimeInterval(-3600), now: fixtureNow))
        precondition(WatchCurveModel.isStale(generatedAt: fixtureNow.addingTimeInterval(-3 * 3600), now: fixtureNow))
        precondition(YaoShiWatchWire.key == "yaoshi.watch.v1")
        print("Watch curve model and R8 wire compatibility passed")
    }
}
