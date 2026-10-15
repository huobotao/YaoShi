import Foundation

/// Shared wire types deliberately have no dependency on the phone's clinical estimates.
enum YaoShiWatchWire {
    static let key = "yaoshi.watch.r7.v1"
    static let maxBytes = 64 * 1024
    static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let data = try? JSONEncoder().encode(value), data.count <= maxBytes else { return nil }
        return data
    }
    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        guard let data = message[key] as? Data, data.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct WatchDoseEvent: Codable, Hashable, Identifiable {
    var id: UUID
    var at: Date
    var mg: Int
    var med: String
    var recordedAt: Date

    func isValid(now: Date = Date()) -> Bool {
        (5...140).contains(mg) && mg % 5 == 0 && med == "Vyvanse"
        && at.timeIntervalSinceReferenceDate.isFinite
        && recordedAt.timeIntervalSinceReferenceDate.isFinite
        && at >= Date(timeIntervalSince1970: 946684800)
        && at <= now.addingTimeInterval(300)
        && recordedAt >= at && recordedAt <= now.addingTimeInterval(300)
    }
    var summary: WatchDoseSummary { .init(id: id, at: at, mg: mg, med: med) }
}

struct WatchDoseSummary: Codable, Hashable, Identifiable {
    var id: UUID
    var at: Date
    var mg: Int
    var med: String
}

struct WatchNoteEvent: Codable, Hashable, Identifiable {
    static let maxCharacters = 500
    static let maxUTF8Bytes = 2_000
    var id: UUID
    var at: Date
    var note: String
    var recordedAt: Date

    func isValid(now: Date = Date()) -> Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && note.count <= Self.maxCharacters && note.utf8.count <= Self.maxUTF8Bytes
        && at.timeIntervalSinceReferenceDate.isFinite
        && recordedAt.timeIntervalSinceReferenceDate.isFinite
        && at >= Date(timeIntervalSince1970: 946684800)
        && at <= now.addingTimeInterval(300)
        && recordedAt >= at && recordedAt <= now.addingTimeInterval(300)
    }
    var summary: WatchNoteSummary { .init(id: id, at: at, note: note) }
}

struct WatchNoteSummary: Codable, Hashable, Identifiable {
    var id: UUID
    var at: Date
    var note: String
}

struct WatchCurveSample: Codable, Equatable {
    var at: Date
    var level: Double
}

struct WatchCurveSnapshot: Codable, Equatable {
    var start: Date
    var end: Date
    var now: Date
    var currentLevel: Double
    var upperLevel: Double
    var samples: [WatchCurveSample]
    var doses: [WatchCurveSample]
}

enum WatchCurveMath {
    static func level(in curve: WatchCurveSnapshot, at date: Date) -> Double? {
        let samples = curve.samples
        guard let first = samples.first, let last = samples.last,
              date >= first.at, date <= last.at else { return nil }
        if date == first.at { return first.level }
        for (left, right) in zip(samples, samples.dropFirst()) where date >= left.at && date <= right.at {
            let span = right.at.timeIntervalSince(left.at)
            guard span > 0 else { continue }
            let fraction = date.timeIntervalSince(left.at) / span
            return left.level + (right.level - left.level) * fraction
        }
        return last.level
    }
}

struct WatchPhoneSnapshot: Codable, Equatable {
    var generatedAt: Date
    var defaultMg: Int
    var defaultMed: String = "Vyvanse"
    var latestDose: WatchDoseSummary?
    /// Recent phone records, including today's records. Timestamps are absolute dates.
    var recentDoses: [WatchDoseSummary]
    // Optional additions keep the v1 journal and older phone/watch builds readable.
    var recentNotes: [WatchNoteSummary]? = nil
    var supportsNotes: Bool? = nil
    var curve: WatchCurveSnapshot? = nil

    var allowsRecording: Bool { (5...140).contains(defaultMg) && defaultMg % 5 == 0 && defaultMed == "Vyvanse" }
}

struct WatchPhoneRequest: Codable {
    var version = 1
    var event: WatchDoseEvent?
    var noteEvent: WatchNoteEvent? = nil

    var deliveryKey: String? {
        guard event == nil || noteEvent == nil else { return nil }
        if let event { return "dose:" + event.id.uuidString }
        if let noteEvent { return "note:" + noteEvent.id.uuidString }
        return nil
    }
}

struct WatchPhoneReply: Codable {
    var version = 1
    var snapshot: WatchPhoneSnapshot?
    /// IDs only appear here after the phone verified durable storage (or a durable deletion).
    var acknowledgedIDs: [UUID] = []
    /// A separate ACK namespace prevents an older phone or a dose ACK clearing a note.
    var acknowledgedNoteIDs: [UUID]? = nil
    var error: String?
}

struct WatchLocalState: Codable, Equatable {
    var version = 1
    var snapshot: WatchPhoneSnapshot?
    var pending: [WatchDoseEvent] = []
    var pendingNotes: [WatchNoteEvent] = []

    init() {}
    private enum CodingKeys: String, CodingKey { case version, snapshot, pending, pendingNotes }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        snapshot = try container.decodeIfPresent(WatchPhoneSnapshot.self, forKey: .snapshot)
        pending = try container.decode([WatchDoseEvent].self, forKey: .pending)
        pendingNotes = try container.decodeIfPresent([WatchNoteEvent].self, forKey: .pendingNotes) ?? []
    }

    mutating func enqueue(_ event: WatchDoseEvent) {
        guard !pending.contains(where: { $0.id == event.id }) else { return }
        pending.append(event)
    }
    mutating func enqueue(_ event: WatchNoteEvent) {
        guard !pendingNotes.contains(where: { $0.id == event.id }) else { return }
        pendingNotes.append(event)
    }
    mutating func absorb(_ reply: WatchPhoneReply) {
        guard reply.version == 1 else { return }
        if let incoming = reply.snapshot,
           snapshot.map({ incoming.generatedAt >= $0.generatedAt }) ?? true {
            snapshot = incoming
        }
        let acknowledged = Set(reply.acknowledgedIDs)
        pending.removeAll { acknowledged.contains($0.id) }
        let acknowledgedNotes = Set(reply.acknowledgedNoteIDs ?? [])
        pendingNotes.removeAll { acknowledgedNotes.contains($0.id) }
    }
    var records: [WatchDoseSummary] {
        var byID = Dictionary((snapshot?.recentDoses ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let latest = snapshot?.latestDose { byID[latest.id] = latest }
        for event in pending where byID[event.id] == nil { byID[event.id] = event.summary }
        return byID.values.sorted { $0.at > $1.at }
    }
    var notes: [WatchNoteSummary] {
        var byID = Dictionary((snapshot?.recentNotes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for event in pendingNotes where byID[event.id] == nil { byID[event.id] = event.summary }
        return byID.values.sorted { $0.at > $1.at }
    }
}

/// One atomic file contains both the outbox and the received snapshot. Never clear the
/// outbox on WC delivery success: transport delivery is not an application-level ACK.
final class WatchJournal {
    private(set) var state: WatchLocalState
    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            state = try JSONDecoder().decode(WatchLocalState.self, from: Data(contentsOf: fileURL))
            guard state.version == 1 else { throw JournalError.unsupportedVersion }
        } else { state = WatchLocalState() }
    }

    func commit(_ candidate: WatchLocalState) throws {
        let data = try JSONEncoder().encode(candidate)
        // Validate before replacing the previous durable queue.
        guard try JSONDecoder().decode(WatchLocalState.self, from: data) == candidate else { throw JournalError.verification }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        guard try Data(contentsOf: fileURL) == data else { throw JournalError.verification }
        state = candidate
    }
    enum JournalError: Error { case unsupportedVersion, verification }
}
