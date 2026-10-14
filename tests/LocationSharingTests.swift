import Foundation

@main struct LocationSharingTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }; checks += 1
    }
    static func point(_ date: Date) -> LocationSample {
        LocationSample(sampledAt: date, latitude: -33.8, longitude: 151.2,
                       horizontalAccuracy: 12, networkTransport: "wifi")
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = LocationSharingState()
        check(!state.record(point(now)), "off by default")
        state.enabled = true
        check(state.record(point(now)), "valid sample recorded")
        check(!state.record(point(now.addingTimeInterval(14))), "minimum 15 second spacing")
        check(state.stageBatch(now: now.addingTimeInterval(299)) == nil, "first batch waits five minutes")
        let batch = state.stageBatch(now: now.addingTimeInterval(300))!
        check(batch.samples.count == 1 && state.pendingBatches.count == 1, "due batch staged durably")
        let encodedBatch = try JSONEncoder().encode(batch)
        check(LocationBatch.matchesPayload(encodedBatch), "wire schema detected")
        state.pause()
        check(state.pendingSampleCount == 0 && state.discardedSampleCount == 1, "pause clears queued samples visibly")
        check(state.stageBatch(now: now, force: true) == nil, "paused force cannot transmit")
        var invalid = point(now); invalid.latitude = 91
        check(!invalid.isValid, "invalid coordinates rejected")
        invalid = point(now); invalid.horizontalAccuracy = -1
        check(!invalid.isValid, "invalid accuracy rejected")
        invalid = point(now); invalid.speed = .infinity
        check(!invalid.isValid, "nonfinite optional value rejected")
        let device = UUID()
        let fresh = LocationBatch(deviceID: device, createdAt: now, samples: [point(now)])
        let old = LocationBatch(deviceID: device, createdAt: now, samples: [point(now.addingTimeInterval(-600))])
        check(state.receive(fresh, author: "partner", now: now), "receive accepted")
        check(state.receive(old, author: "partner", now: now), "backfill accepted")
        check(state.latestReceivedSample?.sampledAt == now, "backfill does not overwrite latest")
        check(state.receive(fresh, author: "partner", now: now) && state.receivedBatches.count == 2, "batch replay idempotent")
        let duplicate = LocationBatch(deviceID: device, createdAt: now, samples: [point(now)])
        _ = state.receive(duplicate, author: "partner", now: now)
        check(state.receivedBatches.count == 2, "same device timestamp deduplicated")
        var badBatch = fresh; badBatch.kind = "location.batch.v2"
        check(!state.receive(badBatch, author: "partner", now: now), "unsupported schema rejected")
        badBatch = fresh; badBatch.samples = (0...120).map { point(now.addingTimeInterval(-Double($0))) }
        check(!badBatch.isValid, "oversized batches rejected")
        var full = LocationSharingState(); full.enabled = true
        full.pendingSamples = (0...20_000).map { point(now.addingTimeInterval(Double($0) * 15 - 300_000)) }
        full.prune(now: now)
        check(full.pendingSampleCount == 20_000 && full.discardedSampleCount == 1, "overflow is bounded and visible")
        let staged = full.stageBatch(now: now, force: true)!
        check(staged.samples.count == 120, "each batch limited to 120 points")
        state.prune(now: now.addingTimeInterval(LocationSharingState.retention + 1))
        check(state.latestReceivedSample == nil, "seven day retention enforced")
        let restored = try JSONDecoder().decode(LocationSharingState.self, from: JSONEncoder().encode(full))
        check(restored == full, "durable state roundtrips")
        print("PASS: \(checks) location sharing model checks")
    }
}
