import Foundation

// Compile with the iOS Simulator SDK and run using simctl spawn on a booted iPhone.
// xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
//   -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" Sources/Models.swift Sources/Sync.swift \
//   Sources/DoseEngine.swift Sources/DoseCurveModel.swift Sources/SharedStore.swift \
//   Sources/LiveActivity.swift Sources/DoseActivity.swift tests/LiveActivityTests.swift \
//   -o /tmp/yaoshi-live-activity-tests
// xcrun simctl spawn <booted-iPhone-UDID> /tmp/yaoshi-live-activity-tests
@main struct LiveActivityTests {
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }

    static func close(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-12
    }

    static func main() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hour: TimeInterval = 3600
        let doses = [Dose(at: now.addingTimeInterval(-4 * hour), mg: 80),
                     Dose(at: now.addingTimeInterval(-6 * hour), mg: 40),
                     Dose(at: now.addingTimeInterval(-72 * hour), mg: 40)]
        var snapshot = SharedSnapshot(status: DoseStatus.compute(doses: doses, now: now), targetAt: nil)
        snapshot.recentDoses = doses.map { DoseTick(at: $0.at, mg: $0.mg, food: $0.food) }
        snapshot.plasmaPeakTenthHoursOverride = 52
        snapshot.plasmaHalfLifeTenthHoursOverride = 145
        snapshot.updatedAt = now

        let state = DoseActivityController.state(from: snapshot, now: now)
        let chart = DoseCurveModel(doses: doses, now: now, curve: snapshot.plasmaCurve)
        check((state.concentrationRatio ?? 0) > 1, "stacked plasma is not clamped to one")
        check(close(state.concentrationRatio, chart.currentLevel), "all records and custom curve agree with main chart")
        check(abs(chart.currentLevel - DoseEngine.totalPlasma(doses, at: now)) > 0.001,
              "custom parameter fixture differs from standard curve")
        check(state.refreshedAt == now, "state records its actual evaluation time")

        var futureSnapshot = snapshot
        futureSnapshot.recentDoses?.append(DoseTick(at: now.addingTimeInterval(hour), mg: 400, food: .empty))
        let futureState = DoseActivityController.state(from: futureSnapshot, now: now)
        check(close(futureState.concentrationRatio, chart.currentLevel), "future records do not change current plasma")

        let last = Dose(at: now.addingTimeInterval(-4 * hour), mg: 80)
        var legacy = SharedSnapshot(status: DoseStatus.compute(doses: [last], now: now), targetAt: nil)
        legacy.plasmaPeakTenthHoursOverride = 52
        legacy.plasmaHalfLifeTenthHoursOverride = 145
        check(legacy.recentDoses == nil, "legacy fixture omits record array")
        let legacyState = DoseActivityController.state(from: legacy, now: now)
        check(close(legacyState.concentrationRatio, DoseEngine.totalPlasma([last], at: now, curve: legacy.plasmaCurve)),
              "missing record array falls back to last dose with custom curve")
        legacy.recentDoses = []
        check(DoseActivityController.state(from: legacy, now: now).concentrationRatio == nil,
              "explicitly empty records never fall back to stale last dose")

        var noHistory = SharedSnapshot.empty
        noHistory.status.generatedAt = now
        check(DoseActivityController.state(from: noHistory, now: now).concentrationRatio == nil,
              "missing last dose and records leaves plasma unavailable")
        legacy.recentDoses = nil
        legacy.status.lastDoseAt = now.addingTimeInterval(hour)
        check(DoseActivityController.state(from: legacy, now: now).concentrationRatio == nil,
              "future fallback last dose is excluded")

        let encoded = try JSONEncoder().encode(state)
        check(encoded.count < 4096, "typical activity state stays below four kilobytes")
        let decoded = try JSONDecoder().decode(DoseAttributes.ContentState.self, from: encoded)
        check(decoded == state, "new activity state round trips without losing plasma")
        var oldObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldObject.removeValue(forKey: "concentrationRatio")
        oldObject.removeValue(forKey: "predictedPeakAt")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let oldState = try JSONDecoder().decode(DoseAttributes.ContentState.self, from: oldData)
        check(oldState.concentrationRatio == nil, "old JSON without plasma decodes compatibly")
        check(oldState.predictedPeakAt == nil, "old JSON without peak decodes compatibly")
        check(oldState.lastDoseAt == state.lastDoseAt && oldState.level == state.level,
              "old activity retains its existing fields")

        check(state.predictedPeakAt == DoseEngine.nextLocalPlasmaPeak(doses: doses, now: now, curve: snapshot.plasmaCurve),
              "activity peak agrees with same records and model parameters")
        var peakDue = state
        peakDue.predictedPeakAt = now.addingTimeInterval(15)
        check(DoseActivityController.nextStale(for: peakDue, now: now) == peakDue.predictedPeakAt,
              "peak countdown expires exactly at predicted peak")
        let staleAt = DoseActivityController.nextStale(for: state, now: now)
        check(staleAt > now && staleAt <= now.addingTimeInterval(300),
              "fresh activity becomes stale within five minutes")
        var early = state
        early.peakEndAt = now.addingTimeInterval(30)
        check(DoseActivityController.nextStale(for: early, now: now) <= early.peakEndAt!,
              "earlier state transition remains the stale deadline")
        check(DoseActivityController.nextStale(for: oldState, now: now) <= now.addingTimeInterval(300),
              "old content also gets a bounded stale deadline")
        print("PASS: \(passed) live activity checks; state JSON \(encoded.count) bytes")
    }
}
