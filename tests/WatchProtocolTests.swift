import Foundation

@main enum WatchProtocolTests {
    static func main() throws {
        let now = Date()
        let id = UUID()
        let event = WatchDoseEvent(id: id, at: now, mg: 40, med: "Vyvanse", recordedAt: now)
        precondition(event.isValid(now: now))
        var invalid = event; invalid.mg = 0
        precondition(!invalid.isValid(now: now))
        invalid = event; invalid.at = now.addingTimeInterval(301)
        precondition(!invalid.isValid(now: now))
        invalid = event; invalid.med = "Unknown"
        precondition(!invalid.isValid(now: now))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yaoshi-watch-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = try WatchJournal(fileURL: file)
        var state = journal.state
        let snapshot = WatchPhoneSnapshot(generatedAt: now, defaultMg: 40, latestDose: nil, recentDoses: [])
        state.snapshot = snapshot
        state.enqueue(event); state.enqueue(event)
        precondition(state.pending.count == 1, "Retry must preserve UUID and remain one event")
        try journal.commit(state)
        let restarted = try WatchJournal(fileURL: file)
        precondition(restarted.state.pending == [event], "Offline outbox must survive restart")
        precondition(restarted.state.records == [event.summary], "Pending dose must be visible locally")

        var confirmationOnly = WatchPhoneReply(snapshot: .init(generatedAt: now.addingTimeInterval(1), defaultMg: 40,
                                                              latestDose: event.summary, recentDoses: [event.summary]))
        state.absorb(confirmationOnly)
        precondition(state.pending.count == 1, "Seeing a snapshot is not a durable ACK")
        precondition(state.records.count == 1, "Snapshot plus pending must not double-count")
        state.absorb(.init(snapshot: nil, acknowledgedIDs: [UUID()]))
        precondition(state.pending.count == 1, "Unknown ACK cannot clear a pending event")
        confirmationOnly.acknowledgedIDs = [event.id]
        state.absorb(confirmationOnly)
        state.absorb(confirmationOnly)
        precondition(state.pending.isEmpty && state.records.count == 1, "ACK replay is idempotent")
        state.absorb(.init(snapshot: snapshot))
        precondition(state.snapshot?.latestDose?.id == event.id, "Out-of-order snapshot cannot roll records back")
        try journal.commit(state)
        let acknowledgedRestart = try WatchJournal(fileURL: file)
        precondition(acknowledgedRestart.state.pending.isEmpty)

        // An ACK for a phone-side tombstone clears the outbox without reviving the record.
        state.enqueue(event)
        state.absorb(.init(snapshot: .init(generatedAt: now.addingTimeInterval(2), defaultMg: 40,
                                         latestDose: nil, recentDoses: []), acknowledgedIDs: [id]))
        precondition(state.pending.isEmpty && state.records.isEmpty)

        // Failed writes retain in-memory state, so callers cannot claim a new record was saved.
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let blockedJournal = try WatchJournal(fileURL: blocked.appendingPathComponent("journal.json"))
        do { try blockedJournal.commit(state); fatalError("Should not write through a regular file") }
        catch { precondition(blockedJournal.state == WatchLocalState()) }
        try Data("corrupt".utf8).write(to: file)
        do { _ = try WatchJournal(fileURL: file); fatalError("Corruption cannot silently erase outbox") }
        catch { }

        let encoded = YaoShiWatchWire.encode(WatchPhoneRequest(event: event))!
        let decoded = YaoShiWatchWire.decode(WatchPhoneRequest.self, from: [YaoShiWatchWire.key: encoded])
        precondition(decoded?.event == event)
        precondition(YaoShiWatchWire.decode(WatchPhoneReply.self, from: [YaoShiWatchWire.key: Data(repeating: 0, count: 65537)]) == nil)

        // Notes are independently useful without a phone snapshot, and never become dose events.
        let note = WatchNoteEvent(id: id, at: now, note: "现在药效挺好，感觉很专注。", recordedAt: now)
        precondition(note.isValid(now: now))
        var invalidNote = note; invalidNote.note = " \n "
        precondition(!invalidNote.isValid(now: now))
        invalidNote.note = String(repeating: "字", count: 501)
        precondition(!invalidNote.isValid(now: now))
        invalidNote.note = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        precondition(!invalidNote.isValid(now: now), "UTF-8 bytes are capped even for multi-scalar graphemes")
        invalidNote = note; invalidNote.at = now.addingTimeInterval(301)
        precondition(!invalidNote.isValid(now: now))
        var noteState = WatchLocalState()
        noteState.enqueue(note); noteState.enqueue(note)
        precondition(noteState.pendingNotes == [note] && noteState.notes == [note.summary])
        precondition(noteState.records.isEmpty, "A note must never create a dose")
        try journal.commit(noteState)
        let noteRestart = try WatchJournal(fileURL: file)
        precondition(noteRestart.state == noteState, "Offline notes survive restart without any phone snapshot")
        noteState.enqueue(event)
        noteState.absorb(.init(acknowledgedIDs: [id]))
        precondition(noteState.pendingNotes == [note] && noteState.pending.isEmpty, "Legacy/dose ACK cannot acknowledge a note with the same UUID")
        let noteSnapshot = WatchPhoneSnapshot(generatedAt: now, defaultMg: 40, recentDoses: [], recentNotes: [note.summary], supportsNotes: true)
        noteState.absorb(.init(snapshot: noteSnapshot))
        precondition(noteState.pendingNotes == [note] && noteState.notes.count == 1, "A snapshot is not a note ACK and must not duplicate a pending note")
        noteState.absorb(.init(acknowledgedNoteIDs: [UUID()]))
        precondition(noteState.pendingNotes == [note])
        noteState.absorb(.init(snapshot: noteSnapshot, acknowledgedNoteIDs: [id]))
        noteState.absorb(.init(snapshot: noteSnapshot, acknowledgedNoteIDs: [id]))
        precondition(noteState.pendingNotes.isEmpty && noteState.notes == [note.summary], "Note ACK replay is idempotent")
        var olderSnapshot = noteSnapshot
        olderSnapshot.generatedAt = now.addingTimeInterval(-1)
        olderSnapshot.recentNotes = []
        noteState.absorb(.init(snapshot: olderSnapshot))
        precondition(noteState.notes == [note.summary], "Stale snapshot cannot erase confirmed note")
        noteState.enqueue(note)
        var deletedSnapshot = noteSnapshot
        deletedSnapshot.generatedAt = now.addingTimeInterval(1)
        deletedSnapshot.recentNotes = []
        noteState.absorb(.init(snapshot: deletedSnapshot, acknowledgedNoteIDs: [id]))
        precondition(noteState.pendingNotes.isEmpty && noteState.notes.isEmpty, "Durable phone deletion clears pending note without resurrection")

        // Simulate an installed v1 journal and a v1 phone that knows only dose fields.
        var legacyState = WatchLocalState()
        legacyState.snapshot = snapshot
        legacyState.enqueue(event)
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyState)) as! [String: Any]
        legacyObject.removeValue(forKey: "pendingNotes")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: file)
        let migrated = try WatchJournal(fileURL: file).state
        precondition(migrated.pending == [event] && migrated.pendingNotes.isEmpty && migrated.snapshot == snapshot)
        struct LegacyPhoneRequest: Decodable { var version: Int; var event: WatchDoseEvent? }
        let noteBytes = YaoShiWatchWire.encode(WatchPhoneRequest(noteEvent: note))!
        let legacyRequest = try JSONDecoder().decode(LegacyPhoneRequest.self, from: noteBytes)
        precondition(legacyRequest.version == 1 && legacyRequest.event == nil, "Old phone sees no dose to accept or ACK")
        let noteRequest = YaoShiWatchWire.decode(WatchPhoneRequest.self, from: [YaoShiWatchWire.key: noteBytes])!
        precondition(noteRequest.noteEvent == note && noteRequest.event == nil)
        precondition(noteRequest.deliveryKey != WatchPhoneRequest(event: event).deliveryKey, "Background transfer deduplication separates event types")
        precondition(WatchPhoneRequest(event: event, noteEvent: note).deliveryKey == nil, "Mixed event requests cannot be queued")

        // Phone snapshots cap notes at 12 and doses at 100; even escaped maximum-length text fits.
        let escapedText = String(repeating: "\u{0001}", count: WatchNoteEvent.maxCharacters)
        let largest = WatchPhoneSnapshot(generatedAt: now, defaultMg: 40, latestDose: event.summary,
                                        recentDoses: (0..<100).map { _ in .init(id: UUID(), at: now, mg: 140, med: "Vyvanse") },
                                        recentNotes: (0..<12).map { _ in .init(id: UUID(), at: now, note: escapedText) }, supportsNotes: true)
        precondition(YaoShiWatchWire.encode(WatchPhoneReply(snapshot: largest, acknowledgedNoteIDs: [id])) != nil,
                     "Maximum normal snapshot and note ACK must fit the 64 KiB wire limit")
        print("Watch protocol tests passed: dose/note offline restart, UUID retries, separate ACKs, v1 migration, legacy phone, stale snapshots, deletions, write failure, corruption, text and wire limits.")
    }
}
