import Foundation

// Compile with the iOS Simulator SDK and run using simctl spawn on a booted iPhone.
// xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
//   -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" Sources/Models.swift Sources/Sync.swift \
//   Sources/DoseEngine.swift Sources/DoseCurveModel.swift Sources/SharedStore.swift \
//   Sources/LiveActivity.swift Sources/DoseActivity.swift Sources/LiveActivityPush.swift Tests/LiveActivityTests.swift \
//   -o /tmp/yaoshi-live-activity-tests
// xcrun simctl spawn <booted-iPhone-UDID> /tmp/yaoshi-live-activity-tests
@main @MainActor struct LiveActivityTests {
    static var passed = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }

    static func close(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-12
    }

    static func main() async throws {
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
        snapshot.episodeStartedAt = doses[1].at

        var gate = LiveActivityRegistrationGate()
        let sig = Data([1]), token = Data([2])
        let firstJob = gate.begin(activity: "a", fingerprint: sig, token: token)!
        check(gate.begin(activity: "a", fingerprint: sig, token: token) == nil, "identical maintain preserves pending retry instead of starving it")
        let rotatedJob = gate.begin(activity: "a", fingerprint: sig, token: Data([3]))!
        check(rotatedJob != firstJob, "token rotation supersedes pending registration")
        check(!gate.finish(activity: "a", jobID: firstJob), "cancelled old completion cannot clear replacement")
        check(gate.jobID(for: "a") == rotatedJob, "replacement remains pending after obsolete completion")
        let changedJob = gate.begin(activity: "a", fingerprint: Data([4]), token: Data([3]))!
        check(changedJob != rotatedJob, "changed model supersedes pending registration")
        gate.cancel(activity: "a")
        check(gate.jobID(for: "a") == nil, "withdraw cancels local registration immediately")
        let retryJob = gate.begin(activity: "a", fingerprint: sig, token: token)!
        check(gate.finish(activity: "a", jobID: retryJob), "completed attempt releases pending identity")
        check(gate.begin(activity: "a", fingerprint: sig, token: token) != nil, "failed bounded attempt allows later identical retry")
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let beforeMidnight = midnight.addingTimeInterval(-30)
        let eveningDose = Dose(at: midnight.addingTimeInterval(-hour), mg: 50)
        var midnightSnapshot = SharedSnapshot(status: DoseStatus.compute(doses: [eveningDose], now: beforeMidnight), targetAt: nil)
        midnightSnapshot.recentDoses = [DoseTick(at: eveningDose.at, mg: eveningDose.mg, food: eveningDose.food)]
        midnightSnapshot.updatedAt = beforeMidnight
        midnightSnapshot.skippedToday = true
        let overnight = LiveActivityPush.buildSchedule(snapshot: midnightSnapshot, started: beforeMidnight)
        check(overnight[0].contentState.skippedToday, "skip flag remains valid on snapshot day")
        check(!overnight[1].contentState.skippedToday, "skip flag resets at local midnight in background schedule")
        check(overnight[0].contentState.takenToday == 1 && overnight[1].contentState.takenToday == 0, "daily dose count resets at midnight")
        check(close(overnight[1].contentState.concentrationRatio, DoseEngine.totalPlasma([eveningDose], at: midnight, curve: midnightSnapshot.plasmaCurve)), "midnight preserves residual concentration")
        let validConfig = LiveActivityPushConfiguration(endpoint: URL(string: "https://relay.example.test")!, authorizationToken: "synthetic", environment: "sandbox")
        check(validConfig.isUsable(provisionedEnvironment: "development"), "matching signed development profile allows push setup")
        check(!validConfig.isUsable(provisionedEnvironment: nil), "missing push entitlement never requests token")
        check(!validConfig.isUsable(provisionedEnvironment: "production"), "environment mismatch blocks token setup")
        let plaintextConfig = LiveActivityPushConfiguration(endpoint: URL(string: "http://relay.example.test")!, authorizationToken: "synthetic", environment: "sandbox")
        check(!plaintextConfig.isUsable(provisionedEnvironment: "development"), "plaintext relay rejected")
        let schedule = LiveActivityPush.buildSchedule(snapshot: snapshot, started: now)
        check(schedule.count == 960, "relay covers eight hours at thirty-second intervals")
        for index in [0, 119, 959] {
            let entry = schedule[index]
            let at = Date(timeIntervalSince1970: Double(entry.at))
            check(close(entry.contentState.concentrationRatio, DoseEngine.totalPlasma(doses, at: at, curve: snapshot.plasmaCurve)), "scheduled value agrees with local model at slot \(index)")
            check(entry.staleAt > entry.at && entry.staleAt <= entry.at + 120, "delivery jitter expires within two minutes or next boundary")
            check(entry.contentState.refreshedAt == at, "estimate timestamp matches its computation time")
        }
        let encodedEntry = try JSONEncoder().encode(schedule[0])
        let roundTrip = try JSONDecoder().decode(LiveActivityPush.Entry.self, from: encodedEntry)
        check(roundTrip.contentState == schedule[0].contentState, "relay JSON preserves ActivityKit Codable dates and values")
        let state = DoseActivityController.state(from: snapshot, now: now)
        check(state.episodeStartedAt == doses[1].at, "resolved episode is forwarded without inferring from dose ticks")
        var changedEpisode = snapshot
        changedEpisode.episodeStartedAt = nil
        check(LiveActivityPush.fingerprint(snapshot) != LiveActivityPush.fingerprint(changedEpisode),
              "clearing the episode invalidates the push schedule fingerprint")
        check(DoseActivityController.state(from: changedEpisode, now: now).episodeStartedAt == nil,
              "explicitly cleared or missing episode never falls back to earliest dose")
        changedEpisode.episodeStartedAt = now.addingTimeInterval(hour)
        check(DoseActivityController.state(from: changedEpisode, now: now).episodeStartedAt == nil,
              "future episode start cannot display negative elapsed time")
        let modelCurve = state.curve!
        check(modelCurve.isValid(at: now) && modelCurve.samples.count == 97, "curve has a bounded valid payload")
        check(modelCurve.time(at: 64, refreshedAt: now) == now, "current point is sampled at the exact evaluation time")
        check(abs(Double(modelCurve.samples[64]) / 10_000 * modelCurve.upperLevel - state.concentrationRatio!) <= modelCurve.upperLevel / 20_000 + 1e-12,
              "quantized current curve point agrees with the displayed concentration")
        for index in [0, 31, 64, 81, 96] {
            let expected = DoseEngine.totalPlasma(doses, at: modelCurve.time(at: index, refreshedAt: now), curve: snapshot.plasmaCurve)
            let sampled = Double(modelCurve.samples[index]) / 10_000 * modelCurve.upperLevel
            check(abs(sampled - expected) <= modelCurve.upperLevel / 20_000 + 1e-12,
                  "bounded curve uses all history and custom parameters at sample \(index)")
        }
        var malformedCurve = modelCurve
        malformedCurve.samples.append(0)
        check(!malformedCurve.isValid(at: now), "oversized decoded curve is not rendered")
        malformedCurve = modelCurve
        malformedCurve.samples[0] = -1
        check(!malformedCurve.isValid(at: now), "out of range decoded curve is not rendered")
        let chart = DoseCurveModel(doses: doses, now: now, curve: snapshot.plasmaCurve)
        check((state.concentrationRatio ?? 0) > 1, "stacked plasma is not clamped to one")
        check(close(state.concentrationRatio, chart.currentLevel), "all records and custom curve agree with main chart")
        check(abs(chart.currentLevel - DoseEngine.totalPlasma(doses, at: now)) > 0.001,
              "custom parameter fixture differs from standard curve")
        check(close(state.plasmaSlopePerHour, PlasmaTrend.slope(doses: doses, at: now, curve: snapshot.plasmaCurve)),
              "activity slope uses all doses and custom parameters")
        var staleSnapshot = snapshot
        staleSnapshot.status = DoseStatus.compute(doses: doses, now: now.addingTimeInterval(-3 * hour))
        let renewed = DoseActivityController.state(from: staleSnapshot, now: now)
        check(renewed.phaseRaw == state.phaseRaw && renewed.remaining == state.remaining,
              "renewed state recomputes phase and remaining alongside slope")
        check(state.refreshedAt == now, "state records its actual evaluation time")

        var futureSnapshot = snapshot
        futureSnapshot.recentDoses?.append(DoseTick(at: now.addingTimeInterval(hour), mg: 400, food: .empty))
        let futureState = DoseActivityController.state(from: futureSnapshot, now: now)
        check(close(futureState.concentrationRatio, chart.currentLevel), "future records do not change current plasma")
        check(futureState.curve == state.curve, "future records never invent a planned dose in the curve")

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
        check(DoseActivityController.state(from: noHistory, now: now).curve == nil, "empty history has no invented curve")
        legacy.recentDoses = nil
        legacy.status.lastDoseAt = now.addingTimeInterval(hour)
        check(DoseActivityController.state(from: legacy, now: now).concentrationRatio == nil,
              "future fallback last dose is excluded")

        let encoded = try JSONEncoder().encode(state)
        check(encoded.count < 4096, "typical activity state stays below four kilobytes")
        let stateObject = try JSONSerialization.jsonObject(with: encoded)
        let envelope: [String: Any] = ["aps": ["timestamp": Int(now.timeIntervalSince1970), "event": "update",
            "content-state": stateObject, "stale-date": Int(now.timeIntervalSince1970 + 60)]]
        let encodedEnvelope = try JSONSerialization.data(withJSONObject: envelope)
        check(encodedEnvelope.count < 4096,
              "bounded curve fits the complete four kilobyte APNs envelope")
        let decoded = try JSONDecoder().decode(DoseAttributes.ContentState.self, from: encoded)
        check(decoded == state, "new activity state round trips without losing plasma")
        var oldObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldObject.removeValue(forKey: "plasmaSlopePerHour")
        oldObject.removeValue(forKey: "concentrationRatio")
        oldObject.removeValue(forKey: "predictedPeakAt")
        oldObject.removeValue(forKey: "episodeStartedAt")
        oldObject.removeValue(forKey: "curve")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let oldState = try JSONDecoder().decode(DoseAttributes.ContentState.self, from: oldData)
        check(oldState.plasmaSlopePerHour == nil, "old activity slope remains unknown")
        check(oldState.concentrationRatio == nil, "old JSON without plasma decodes compatibly")
        check(oldState.predictedPeakAt == nil, "old JSON without peak decodes compatibly")
        check(oldState.curve == nil && oldState.episodeStartedAt == nil, "old activities omit curve and episode without decode failure")
        var legacySnapshotObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        legacySnapshotObject.removeValue(forKey: "episodeStartedAt")
        let legacySnapshot = try JSONDecoder().decode(SharedSnapshot.self, from: JSONSerialization.data(withJSONObject: legacySnapshotObject))
        check(legacySnapshot.episodeStartedAt == nil, "legacy snapshot does not invent a round start")
        let longHistory = (0..<800).map { Dose(at: now.addingTimeInterval(-Double($0) * hour), mg: 500) }
        var largeSnapshot = snapshot
        largeSnapshot.recentDoses = longHistory.map { DoseTick(at: $0.at, mg: $0.mg, food: $0.food) }
        let largeState = DoseActivityController.state(from: largeSnapshot, now: now, calculatePeak: false)
        check(largeState.curve?.samples.count == 97, "large history never expands the fixed curve sample count")
        let encodedLargeState = try JSONEncoder().encode(largeState)
        check(encodedLargeState.count + 256 < 4096, "large values and history retain room for APNs and attributes")
        check(oldState.lastDoseAt == state.lastDoseAt && oldState.level == state.level,
              "old activity retains its existing fields")

        check(state.predictedPeakAt == DoseEngine.nextLocalPlasmaPeak(doses: doses, now: now, curve: snapshot.plasmaCurve),
              "activity peak agrees with same records and model parameters")
        // The native timer owns elapsed time; the model supplies an immutable deadline.
        var timerState = state
        timerState.refreshedAt = now
        timerState.predictedPeakAt = now.addingTimeInterval(5 * hour)
        let timerInterval = timerState.predictedPeakTimerInterval
        check(timerInterval?.lowerBound == now, "countdown starts at the prediction evaluation time")
        check(timerInterval?.upperBound == timerState.predictedPeakAt, "countdown ends at the fixed predicted peak")
        check(DoseActivityController.nextStale(for: timerState, now: now) < timerInterval!.upperBound,
              "snapshot can become stale before the independent countdown deadline")
        let cachedTimerState = try JSONDecoder().decode(DoseAttributes.ContentState.self,
            from: JSONEncoder().encode(timerState))
        check(cachedTimerState.predictedPeakTimerInterval == timerInterval,
              "cached content preserves the timer interval without a new wall-clock calculation")
        var elapsedTimer = timerState
        elapsedTimer.refreshedAt = Date(timeIntervalSinceReferenceDate: 100)
        elapsedTimer.predictedPeakAt = Date(timeIntervalSinceReferenceDate: 200)
        check(elapsedTimer.predictedPeakTimerInterval?.upperBound == elapsedTimer.predictedPeakAt,
              "expired cached deadline remains available for native timer to display zero")
        timerState.predictedPeakAt = now
        check(timerState.predictedPeakTimerInterval == nil, "zero-duration prediction never creates an invalid timer range")
        timerState.predictedPeakAt = now.addingTimeInterval(-1)
        check(timerState.predictedPeakTimerInterval == nil, "already-past prediction at evaluation time is not a future peak")
        timerState.predictedPeakAt = nil
        check(timerState.predictedPeakTimerInterval == nil, "missing future peak never manufactures a countdown")
        timerState.predictedPeakAt = Date(timeIntervalSinceReferenceDate: .infinity)
        check(timerState.predictedPeakTimerInterval == nil, "infinite prediction is rejected")
        timerState.predictedPeakAt = Date(timeIntervalSinceReferenceDate: .nan)
        check(timerState.predictedPeakTimerInterval == nil, "NaN prediction is rejected")
        timerState.predictedPeakAt = now.addingTimeInterval(hour)
        timerState.refreshedAt = Date(timeIntervalSinceReferenceDate: -.infinity)
        check(timerState.predictedPeakTimerInterval == nil, "nonfinite evaluation time is rejected")
        check(oldState.predictedPeakTimerInterval == nil, "legacy content with no peak remains countdown-free")
        check(DoseActivityController.state(from: noHistory, now: now).predictedPeakTimerInterval == nil,
              "empty dose history cannot invent an upcoming peak")
        check(futureState.predictedPeakAt == state.predictedPeakAt,
              "unrecorded future dose does not alter countdown prediction")
        var falling = SharedSnapshot(status: DoseStatus.compute(doses: [Dose(at: now.addingTimeInterval(-24 * hour), mg: 50)], now: now), targetAt: nil)
        falling.recentDoses = [DoseTick(at: now.addingTimeInterval(-24 * hour), mg: 50, food: .empty)]
        check(DoseActivityController.state(from: falling, now: now).predictedPeakTimerInterval == nil,
              "declining residual alone is not labelled as a future peak")
        let newDose = Dose(at: now, mg: 50)
        let updatedDoses = doses + [newDose]
        var updatedSnapshot = snapshot
        updatedSnapshot.recentDoses = updatedDoses.map { DoseTick(at: $0.at, mg: $0.mg, food: $0.food) }
        let updatedState = DoseActivityController.state(from: updatedSnapshot, now: now)
        check(updatedState.predictedPeakAt == DoseEngine.nextLocalPlasmaPeak(doses: updatedDoses, now: now, curve: snapshot.plasmaCurve),
              "recording a new dose recomputes the total multi-dose curve peak")
        check(updatedState.predictedPeakAt != state.predictedPeakAt && updatedState.predictedPeakTimerInterval != nil,
              "new dose replaces the old countdown deadline")
        var peakDue = state
        peakDue.predictedPeakAt = now.addingTimeInterval(15)
        check(DoseActivityController.nextStale(for: peakDue, now: now) == peakDue.predictedPeakAt,
              "peak countdown expires exactly at predicted peak")
        let staleAt = DoseActivityController.nextStale(for: state, now: now)
        check(staleAt > now && staleAt <= now.addingTimeInterval(60),
              "fresh activity becomes stale within one minute")
        var early = state
        early.peakEndAt = now.addingTimeInterval(30)
        check(DoseActivityController.nextStale(for: early, now: now) <= early.peakEndAt!,
              "earlier state transition remains the stale deadline")
        check(DoseActivityController.nextStale(for: oldState, now: now) <= now.addingTimeInterval(60),
              "old content also gets a bounded stale deadline")
        // Suspend the first system operation so two new requests arrive mid-flight.
        // A concurrent fire-and-forget implementation would overlap or apply 2 after 3.
        var operations: [Int] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        var firstStarted: CheckedContinuation<Void, Never>?
        var activeOperations = 0
        var maxActiveOperations = 0
        let queue = DoseActivityWorkQueue<Int> { value in
            activeOperations += 1
            maxActiveOperations = max(maxActiveOperations, activeOperations)
            if value == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstStarted?.resume()
                }
            }
            operations.append(value)
            activeOperations -= 1
        }
        await withCheckedContinuation { continuation in
            firstStarted = continuation
            queue.submit(1)
        }
        queue.submit(2)
        let completed = queue.submit(3)
        releaseFirst?.resume()
        await completed.value
        check(operations == [1, 3], "pending refreshes coalesce to the newest state")
        check(maxActiveOperations == 1, "system operations never overlap")
        await queue.submit(4).value
        check(operations == [1, 3, 4], "worker restarts after draining")

        print("PASS: \(passed) live activity checks; state JSON \(encoded.count) bytes")
    }
}
