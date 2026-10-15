import Foundation

@main
enum DoseJournalTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dose-journal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let originalImport = StandaloneDose(id: UUID(), at: Date().addingTimeInterval(-3600),
                                            mg: 50, food: "unknown")
        let journal = try DoseJournal(url: url)
        assert(journal.activeLocalDoses().isEmpty)
        let recorded = try journal.record(at: Date().addingTimeInterval(-60))
        assert(recorded.mg == 50 && recorded.food == "unknown")
        assert(journal.events.count == 1)
        assert(journal.pendingDoses(imported: [originalImport]) == [recorded])
        assert(journal.mergedDoses(imported: [originalImport]).count == 2)
        assert(journal.pendingDoses(imported: [originalImport, recorded]).isEmpty)
        let roundedACK = StandaloneDose(id: recorded.id,
                                        at: recorded.at.addingTimeInterval(0.4),
                                        mg: 50, food: "unknown")
        assert(journal.pendingDoses(imported: [originalImport, roundedACK]).isEmpty)
        let differentTime = StandaloneDose(id: recorded.id,
                                          at: recorded.at.addingTimeInterval(1.1),
                                          mg: 50, food: "unknown")
        assert(journal.pendingDoses(imported: [originalImport, differentTime]).count == 1)

        try journal.revise(recorded.id, at: recorded.at, mg: 100, food: "withFood")
        assert(journal.activeLocalDoses().first?.mg == 100)
        assert(journal.events.count == 2)
        let reopenedActive = try DoseJournal(url: url)
        assert(reopenedActive.activeLocalDoses().first?.mg == 100)
        assert(reopenedActive.activeLocalDoses().first?.id == recorded.id)
        assert(abs(reopenedActive.activeLocalDoses()[0].at.timeIntervalSince(recorded.at)) < 1)
        assert(reopenedActive.pendingDoses(imported: [originalImport]).count == 1)
        try journal.remove(recorded.id)
        assert(journal.activeLocalDoses().isEmpty)
        assert(journal.mergedDoses(imported: [originalImport, recorded]) == [originalImport])
        assert(journal.pendingRemovalIDs(imported: [originalImport, recorded]) == Set([recorded.id]))

        let reopened = try DoseJournal(url: url)
        assert(reopened.activeLocalDoses().isEmpty)
        assert(reopened.events.count == 3)
        assert(reopened.mergedDoses(imported: [originalImport]) == [originalImport])

        let before = reopened.events.count
        do {
            try reopened.record(at: Date(), mg: 13, food: "unknown")
            assertionFailure("invalid dose accepted")
        } catch DoseJournalError.invalidDose { }
        assert(reopened.events.count == before)

        let originalBytes = try Data(contentsOf: url)
        try Data("corrupt".utf8).write(to: url, options: .atomic)
        do {
            _ = try DoseJournal(url: url)
            assertionFailure("corrupt journal accepted")
        } catch { }
        try originalBytes.write(to: url, options: .atomic)
        let restored = try DoseJournal(url: url)
        assert(restored.activeLocalDoses().isEmpty)
        assert(restored.events.count == 3)
        print("DoseJournalTests passed")
    }
}
