import Foundation
import Combine

struct Dose: Decodable, Identifiable {
    let id: String
    let at: Date
    let mg: Int
    let note: String
    let food: String

    private enum CodingKeys: String, CodingKey { case id, at, mg, note, food }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        mg = try c.decode(Int.self, forKey: .mg)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        food = try c.decodeIfPresent(String.self, forKey: .food) ?? "unknown"
    }
}

struct Event: Decodable, Identifiable {
    let id: String
    let at: Date
    let kind: String
    let note: String

    private enum CodingKeys: String, CodingKey { case id, at, kind, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(String.self, forKey: .kind)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct Note: Decodable, Identifiable {
    let id: String
    let at: Date
    let note: String

    private enum CodingKeys: String, CodingKey { case id, at, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

private struct SnapshotSettings: Decodable {
    let plasmaPeakTenthHoursOverride: Int?
    let plasmaHalfLifeTenthHoursOverride: Int?
}

private struct Snapshot: Decodable {
    let doses: [Dose]
    let effects: [Note]
    let lifeEvents: [Event]?
    let settings: SnapshotSettings?
    let updatedAt: Date?
}

/// Local snapshot reader only. It never writes, merges, or contacts another device.
final class WorkspaceStore: ObservableObject {
    @Published private(set) var doses: [Dose] = []
    @Published private(set) var events: [Event] = []
    @Published private(set) var notes: [Note] = []
    /// Timestamp recorded inside the source snapshot, not proof of a recent device sync.
    @Published private(set) var capturedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var sourcePath: String
    @Published private(set) var peakHours: Double = 3.8
    @Published private(set) var halfLifeHours: Double = 10.7

    init(sourceURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/YaoShiMacWorkspaceR1/air-snapshot.json")) {
        sourcePath = sourceURL.path
        reload()
    }

    func reload() {
        do {
            let url = URL(fileURLWithPath: sourcePath)
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .deferredToDate // Seconds since 2001, matching Air.
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            try validate(snapshot)
            // Publish only after the entire snapshot passed decoding and validation.
            doses = snapshot.doses.sorted { $0.at < $1.at }
            events = (snapshot.lifeEvents ?? []).sorted { $0.at < $1.at }
            notes = snapshot.effects.sorted { $0.at > $1.at }
            capturedAt = snapshot.updatedAt
            peakHours = Double(min(max(snapshot.settings?.plasmaPeakTenthHoursOverride ?? 38, 10), 120)) / 10
            halfLifeHours = Double(min(max(snapshot.settings?.plasmaHalfLifeTenthHoursOverride ?? 107, 20), 300)) / 10
            error = nil
        } catch {
            self.error = "无法读取本地快照；保留上次成功读取的数据。\(error.localizedDescription)"
        }
    }

    private func validate(_ snapshot: Snapshot) throws {
        func check(_ ids: [String], _ dates: [Date]) throws {
            guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
                  dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
                throw SnapshotError.invalidRecords
            }
        }
        try check(snapshot.doses.map(\.id), snapshot.doses.map(\.at))
        try check(snapshot.effects.map(\.id), snapshot.effects.map(\.at))
        try check((snapshot.lifeEvents ?? []).map(\.id), (snapshot.lifeEvents ?? []).map(\.at))
        guard snapshot.doses.allSatisfy({ $0.mg >= 0 }),
              snapshot.updatedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw SnapshotError.invalidRecords
        }
    }

    /// Same normalized plasma model as Air R4; 1× is the modeled peak of 50 mg.
    /// Includes all historical doses, without clipping to the visible chart range.
    func level(at date: Date) -> Double {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        let ke = log(2.0) / halfLifeHours
        let wanted = max(0.05, peakHours - 0.5)
        var low = ke * 1e-9
        var high = ke * 1e9
        for _ in 0..<100 {
            let mid = (low + high) / 2
            let delta = mid - ke
            let relativeDelta = delta / ke
            let time = abs(relativeDelta) < 1e-6
                ? 1 / ke - delta / (2 * ke * ke)
                : log1p(relativeDelta) / delta
            if time > wanted { low = mid } else { high = mid }
        }
        let ka = (low + high) / 2
        func shape(_ x: Double) -> Double {
            if abs(ka - ke) < max(ka, ke) * 1e-8 { return x * exp(-ke * x) }
            return abs(exp(-ke * x) - exp(-ka * x))
        }
        let peak = shape(wanted)
        guard peak > 0 else { return 0 }
        return doses.reduce(0) { result, dose in
            let t = date.timeIntervalSince(dose.at) / 3600
            let lag = dose.food == "withFood" ? 1.4 : 0.5
            let x = t - lag
            guard t > 0, x > 0, x.isFinite, dose.mg > 0 else { return result }
            return result + max(0, shape(x) / peak) * Double(dose.mg) / 50
        }
    }
}

private enum SnapshotError: LocalizedError {
    case invalidRecords
    var errorDescription: String? { "快照包含重复标识、无效时间或无效剂量，未加载。" }
}
