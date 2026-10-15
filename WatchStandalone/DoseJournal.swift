import Foundation

/// Watch-owned changes are kept apart from the read-only iPhone import. Nothing here
/// writes into the imported snapshot or implies that an iPhone has received a dose.
struct DoseJournalEvent: Codable, Equatable, Identifiable {
    enum Action: String, Codable { case record, revise, remove }

    let id: UUID
    let doseID: UUID
    let action: Action
    let occurredAt: Date
    let dose: StandaloneDose?
}

struct DoseJournalFile: Codable {
    let schema: Int
    let events: [DoseJournalEvent]
}

enum DoseJournalError: Error {
    case invalidFile, unknownDose, invalidDose
}

/// Main-thread-owned store. Each edit appends an event and atomically replaces the
/// journal file; failures leave the previous in-memory and on-disk states intact.
final class DoseJournal {
    private(set) var events: [DoseJournalEvent]
    let url: URL

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 4_000_000 else { throw DoseJournalError.invalidFile }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let file = try decoder.decode(DoseJournalFile.self, from: bytes)
            guard file.schema == 1, file.events.count <= 20_000,
                  Set(file.events.map(\.id)).count == file.events.count else {
                throw DoseJournalError.invalidFile
            }
            try Self.validate(file.events)
            events = file.events
        } else {
            events = []
        }
    }

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YaoShi-Standalone-Air-R4/watch-dose-journal-v1.json")
    }

    private static func validateDose(_ dose: StandaloneDose) throws {
        guard (5...500).contains(dose.mg), dose.mg % 5 == 0,
              ["unknown", "withFood", "emptyStomach"].contains(dose.food),
              dose.at >= Date(timeIntervalSince1970: 946684800),
              dose.at <= Date().addingTimeInterval(300) else { throw DoseJournalError.invalidDose }
    }

    private static func validate(_ events: [DoseJournalEvent]) throws {
        var known = Set<UUID>()
        for event in events {
            guard event.occurredAt >= Date(timeIntervalSince1970: 946684800),
                  event.occurredAt <= Date().addingTimeInterval(300) else {
                throw DoseJournalError.invalidFile
            }
            switch event.action {
            case .record:
                guard let dose = event.dose, dose.id == event.doseID,
                      !known.contains(event.doseID) else { throw DoseJournalError.invalidFile }
                try validateDose(dose)
                known.insert(event.doseID)
            case .revise:
                guard let dose = event.dose, dose.id == event.doseID,
                      known.contains(event.doseID) else { throw DoseJournalError.invalidFile }
                try validateDose(dose)
            case .remove:
                guard event.dose == nil, known.contains(event.doseID) else {
                    throw DoseJournalError.invalidFile
                }
            }
        }
    }

    private func append(_ event: DoseJournalEvent) throws {
        let next = events + [event]
        guard next.count <= 20_000 else { throw DoseJournalError.invalidFile }
        try Self.validate(next)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(DoseJournalFile(schema: 1, events: next))
        guard bytes.count <= 4_000_000 else { throw DoseJournalError.invalidFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        events = next
    }

    @discardableResult
    func record(at: Date = Date(), mg: Int = 50, food: String = "unknown") throws -> StandaloneDose {
        let dose = StandaloneDose(id: UUID(), at: at, mg: mg, food: food)
        try append(DoseJournalEvent(id: UUID(), doseID: dose.id, action: .record,
                                    occurredAt: Date(), dose: dose))
        return dose
    }

    /// Revises a Watch-created dose. The old value remains in the journal.
    func revise(_ doseID: UUID, at: Date, mg: Int, food: String) throws {
        guard activeLocalDoses().contains(where: { $0.id == doseID }) else {
            throw DoseJournalError.unknownDose
        }
        let dose = StandaloneDose(id: doseID, at: at, mg: mg, food: food)
        try append(DoseJournalEvent(id: UUID(), doseID: doseID, action: .revise,
                                    occurredAt: Date(), dose: dose))
    }

    func remove(_ doseID: UUID) throws {
        guard activeLocalDoses().contains(where: { $0.id == doseID }) else {
            throw DoseJournalError.unknownDose
        }
        try append(DoseJournalEvent(id: UUID(), doseID: doseID, action: .remove,
                                    occurredAt: Date(), dose: nil))
    }

    private static func replay(_ events: [DoseJournalEvent]) -> [UUID: StandaloneDose] {
        var doses: [UUID: StandaloneDose] = [:]
        for event in events {
            switch event.action {
            case .record, .revise: doses[event.doseID] = event.dose
            case .remove: doses[event.doseID] = nil
            }
        }
        return doses
    }

    func activeLocalDoses() -> [StandaloneDose] {
        Self.replay(events).values.sorted { $0.at < $1.at }
    }

    /// Imported UUIDs win when they already match. Any conflicting local entry
    /// remains pending and visible as the Watch version, without mutating import.
    func mergedDoses(imported: [StandaloneDose]) -> [StandaloneDose] {
        var result = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })
        for doseID in removedLocalDoseIDs() { result[doseID] = nil }
        for dose in activeLocalDoses() { result[dose.id] = dose }
        return result.values.sorted { $0.at < $1.at }
    }

    func pendingDoses(imported: [StandaloneDose]) -> [StandaloneDose] {
        let importedByID = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })
        return activeLocalDoses().filter { local in
            guard let remote = importedByID[local.id] else { return true }
            return !Self.sameDose(local, remote)
        }
    }

    private static func sameDose(_ lhs: StandaloneDose, _ rhs: StandaloneDose) -> Bool {
        lhs.id == rhs.id && lhs.mg == rhs.mg && lhs.food == rhs.food &&
            abs(lhs.at.timeIntervalSince(rhs.at)) < 1
    }

    /// IDs to delete on the iPhone *if* a later, separately implemented sync
    /// explicitly carries and acknowledges these changes.
    func pendingRemovalIDs(imported: [StandaloneDose]) -> Set<UUID> {
        let importedIDs = Set(imported.map(\.id))
        return removedLocalDoseIDs().intersection(importedIDs)
    }

    private func removedLocalDoseIDs() -> Set<UUID> {
        let created = Set(events.filter { $0.action == .record }.map(\.doseID))
        return created.subtracting(activeLocalDoses().map(\.id))
    }
}
