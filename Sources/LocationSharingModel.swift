import Foundation

struct LocationSample: Codable, Identifiable, Equatable {
    var id = UUID()
    var sampledAt: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double? = nil
    var verticalAccuracy: Double? = nil
    var speed: Double? = nil
    var course: Double? = nil
    var networkTransport: String

    var isValid: Bool {
        sampledAt.timeIntervalSince1970.isFinite && latitude.isFinite && longitude.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude) &&
        horizontalAccuracy.isFinite && horizontalAccuracy >= 0 &&
        (altitude == nil || altitude!.isFinite) &&
        (verticalAccuracy == nil || (verticalAccuracy!.isFinite && verticalAccuracy! >= 0)) &&
        (speed == nil || (speed!.isFinite && speed! >= 0)) &&
        (course == nil || (course!.isFinite && (0..<360).contains(course!))) &&
        networkTransport.utf8.count <= 64
    }
}

struct LocationBatch: Codable, Identifiable, Equatable {
    static let schema = "location.batch.v1"
    var id = UUID()
    var kind = LocationBatch.schema
    var deviceID: UUID
    var createdAt: Date
    var samples: [LocationSample]

    var isValid: Bool {
        kind == Self.schema && createdAt.timeIntervalSince1970.isFinite &&
        !samples.isEmpty && samples.count <= 120 && samples.allSatisfy(\.isValid) &&
        Set(samples.map(\.id)).count == samples.count &&
        Set(samples.map(\.sampledAt)).count == samples.count
    }

    static func matchesPayload(_ data: Data) -> Bool {
        struct Header: Decodable { var kind: String }
        return (try? JSONDecoder().decode(Header.self, from: data).kind) == schema
    }
}

struct LocationReceivedBatch: Codable, Equatable {
    var batch: LocationBatch
    var author: String
    var receivedAt: Date
}

struct LocationSharingState: Codable, Equatable {
    static let maximumSamples = 20_000
    static let retention: TimeInterval = 7 * 24 * 3600
    var enabled = false
    var boundSpaceID: String? = nil
    var boundServer: String? = nil
    var deviceID = UUID()
    var receivedSpaceID: String? = nil
    var receivedServer: String? = nil
    var pendingSamples: [LocationSample] = []
    var pendingBatches: [LocationBatch] = []
    var receivedBatches: [LocationReceivedBatch] = []
    var localSamples: [LocationSample] = []
    var lastUploadAt: Date? = nil
    var lastBatchAt: Date? = nil
    var lastRecordedAt: Date? = nil
    /// Counts unsent samples discarded by retention, capacity limits, or pause.
    var discardedSampleCount = 0

    var latestReceivedSample: LocationSample? {
        receivedBatches.flatMap { $0.batch.samples }.max { $0.sampledAt < $1.sampledAt }
    }
    var pendingSampleCount: Int { pendingSamples.count + pendingBatches.reduce(0) { $0 + $1.samples.count } }

    @discardableResult
    mutating func record(_ sample: LocationSample) -> Bool {
        guard enabled, sample.isValid else { return false }
        if let lastRecordedAt, sample.sampledAt.timeIntervalSince(lastRecordedAt) < 15 { return false }
        lastRecordedAt = sample.sampledAt
        localSamples.append(sample)
        pendingSamples.append(sample)
        prune(now: sample.sampledAt)
        return true
    }

    /// Five minutes is a batching target, not a promise of iOS background execution.
    @discardableResult
    mutating func stageBatch(now: Date, force: Bool = false) -> LocationBatch? {
        guard enabled else { return nil }
        prune(now: now)
        guard let first = pendingSamples.first,
              force || now.timeIntervalSince(lastBatchAt ?? first.sampledAt) >= 300 else { return nil }
        let samples = Array(pendingSamples.prefix(120))
        let batch = LocationBatch(deviceID: deviceID, createdAt: now, samples: samples)
        pendingSamples.removeFirst(samples.count)
        pendingBatches.append(batch)
        lastBatchAt = now
        return batch
    }

    @discardableResult
    mutating func receive(_ batch: LocationBatch, author: String, now: Date) -> Bool {
        guard batch.isValid, !author.isEmpty, author.utf8.count <= 64,
              batch.samples.allSatisfy({ $0.sampledAt <= now.addingTimeInterval(300) }) else { return false }
        if receivedBatches.contains(where: { $0.batch.id == batch.id }) { return true }
        let existing = receivedBatches.filter { $0.batch.deviceID == batch.deviceID && $0.author == author }
            .flatMap { $0.batch.samples }
        let timestamps = Set(existing.map(\.sampledAt))
        let ids = Set(existing.map(\.id))
        var unique = batch
        unique.samples = batch.samples.filter { !timestamps.contains($0.sampledAt) && !ids.contains($0.id) }
        if !unique.samples.isEmpty {
            receivedBatches.append(LocationReceivedBatch(batch: unique, author: author, receivedAt: now))
        }
        prune(now: now)
        return true
    }

    mutating func pause() {
        enabled = false
        discardedSampleCount += pendingSampleCount
        pendingSamples.removeAll()
        pendingBatches.removeAll()
        lastBatchAt = nil
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        localSamples.removeAll { $0.sampledAt < cutoff }
        if localSamples.count > Self.maximumSamples {
            localSamples.removeFirst(localSamples.count - Self.maximumSamples)
        }
        let before = pendingSampleCount
        pendingSamples.removeAll { $0.sampledAt < cutoff }
        // Never mutate a staged event: its UUID is also the relay's idempotency key.
        pendingBatches.removeAll { $0.samples.contains { $0.sampledAt < cutoff } }
        var excess = max(0, pendingSampleCount - Self.maximumSamples)
        while excess > 0, !pendingBatches.isEmpty {
            excess -= pendingBatches.removeFirst().samples.count
        }
        if excess > 0 { pendingSamples.removeFirst(min(excess, pendingSamples.count)) }
        discardedSampleCount += before - pendingSampleCount

        for index in receivedBatches.indices {
            receivedBatches[index].batch.samples.removeAll { $0.sampledAt < cutoff }
        }
        receivedBatches.removeAll { $0.batch.samples.isEmpty }
        let ordered = receivedBatches.flatMap { item in
            item.batch.samples.map { (batch: item.batch.id, sample: $0) }
        }.sorted { $0.sample.sampledAt > $1.sample.sampledAt }
        if ordered.count > Self.maximumSamples {
            let retained = Set(ordered.prefix(Self.maximumSamples).map { "\($0.batch):\($0.sample.id)" })
            for index in receivedBatches.indices {
                let batchID = receivedBatches[index].batch.id
                receivedBatches[index].batch.samples.removeAll { !retained.contains("\(batchID):\($0.id)") }
            }
            receivedBatches.removeAll { $0.batch.samples.isEmpty }
        }
    }
}
