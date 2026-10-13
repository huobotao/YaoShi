import Foundation
import Security

// Tests only: Store's external UI/notification effects are disabled by SYNC_TESTING.
@MainActor enum Notifier { static func reschedule(_ store: Store) {} }

final class FakeKeychain: SyncKeychainAccess {
    var items: [String: Data] = [:]
    var readFailure: OSStatus?
    var writeFailure: OSStatus?
    var updates = 0
    var adds = 0

    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        if let readFailure { return (readFailure, nil) }
        if let account = query[kSecAttrAccount as String] as? String {
            guard let item = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item)
        }
        guard !items.isEmpty else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, items.map { [kSecAttrAccount as String: $0.key,
                                         kSecValueData as String: $0.value] as [String: Any] })
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates += 1
        if let writeFailure { return writeFailure }
        let account = query[kSecAttrAccount as String] as! String
        guard items[account] != nil else { return errSecItemNotFound }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        adds += 1
        if let writeFailure { return writeFailure }
        items[attributes[kSecAttrAccount as String] as! String] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
}

@main struct SyncRegressionTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }

    @MainActor static func main() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var doseA = Dose(at: timestamp, mg: 40)
        doseA.updatedAt = timestamp
        let legacyDoseData = try JSONEncoder().encode(doseA)
        let legacyDoseObject = try JSONSerialization.jsonObject(with: legacyDoseData) as! [String: Any]
        check(legacyDoseObject["pillCount"] == nil, "unknown count retains historical JSON shape")
        let legacyDose = try JSONDecoder().decode(Dose.self, from: legacyDoseData)
        check(legacyDose.pillCount == nil && legacyDose.mg == 40,
              "historical milligram records decode with unknown count and unchanged dose")
        let countedDose = Dose(at: timestamp, mg: 100, pillCount: 2)
        let countRoundTrip = try JSONDecoder().decode(Dose.self, from: JSONEncoder().encode(countedDose))
        check(countRoundTrip.pillCount == 2 && countRoundTrip.mg == 100,
              "explicit actual count survives serialization independently of milligrams")
        var doseB = Dose(at: timestamp.addingTimeInterval(300), mg: 40)
        doseB.updatedAt = timestamp
        var a = SyncPayload(); a.doses = [doseA]
        var b = SyncPayload(); b.doses = [doseB]
        let merged = SyncMerge.merge(local: a, remote: b)
        check(merged.doses.count == 2, "independent offline additions survive")
        check(SyncStore.fingerprint(merged) == SyncStore.fingerprint(SyncMerge.merge(local: b, remote: a)), "commutative merge")
        check(SyncStore.fingerprint(merged) == SyncStore.fingerprint(SyncMerge.merge(local: merged, remote: a)), "idempotent merge")

        var conflict = doseA; conflict.mg = 50
        var c = SyncPayload(); c.doses = [conflict]
        check(SyncStore.fingerprint(SyncMerge.merge(local: a, remote: c)) == SyncStore.fingerprint(SyncMerge.merge(local: c, remote: a)), "equal timestamp conflicts converge")
        var deletion = SyncPayload()
        deletion.tombstones[doseA.syncKey] = timestamp.addingTimeInterval(1)
        check(SyncMerge.merge(local: a, remote: deletion).doses.isEmpty, "old deletion survives long offline interval")
        check(SyncMerge.merge(local: a, remote: deletion).tombstones.count == 1, "no TTL resurrection")
        var settings = SyncedSettings(); settings.defaultMg = 50; settings.updatedAt = timestamp
        a.settings = settings; b.settings = SyncedSettings()
        check(SyncMerge.merge(local: b, remote: a).settings?.defaultMg == 50, "new install default does not overwrite prior settings")

        var stock = Supply(); stock.pillsLeft = 9; stock.updatedAt = timestamp
        var stockA = a; stockA.supply = stock
        var stockB = b; stockB.supply = stock
        let stockConflict = SyncMerge.merge(local: stockA, remote: stockB)
        check(stockConflict.doses.count == 2 && stockConflict.inventory?.needsReview == true, "concurrent doses flag inventory even when both counts match")
        check(stockConflict.supply?.pillsLeft == 9, "inventory conflict does not guess actual quantity")
        var resolved = stockConflict
        resolved.inventory?.resolvedAt = timestamp.addingTimeInterval(10)
        check(SyncMerge.merge(local: resolved, remote: stockConflict).inventory?.needsReview == false, "old inventory conflict cannot revive after explicit resolution")
        var refillA = stockA; refillA.doses = []; refillA.supply?.pillsLeft = 20
        var refillB = stockB; refillB.doses = []; refillB.supply?.pillsLeft = 30
        check(SyncMerge.merge(local: refillA, remote: refillB).inventory?.needsReview == true, "concurrent inventory edits without dose additions also flagged")
        check(SyncStore.fingerprint(stockConflict) == SyncStore.fingerprint(SyncMerge.merge(local: stockB, remote: stockA)), "inventory conflicts merge symmetrically")

        let keychain = FakeKeychain()
        check(SyncStore.push(a, using: keychain, account: "payload-v2-A").isOK, "first device publishes")
        check(SyncStore.push(b, using: keychain, account: "payload-v2-B").isOK, "second device publishes")
        check(keychain.items.count == 2, "per-device entries do not overwrite peers")
        let reads = try SyncStore.pull(using: keychain).get()
        check(reads.snapshots.count == 2, "read all device snapshots")
        let writes = keychain.updates + keychain.adds
        check(SyncStore.push(a, using: keychain, account: "payload-v2-A").isOK, "unchanged publish succeeds")
        check(writes == keychain.updates + keychain.adds, "unchanged content avoids keychain churn")
        let previous = keychain.items["payload-v2-A"]
        keychain.writeFailure = errSecNotAvailable
        check(!SyncStore.push(merged, using: keychain, account: "payload-v2-A").isOK, "write failure reported")
        check(previous == keychain.items["payload-v2-A"], "failed update retains previous value")
        keychain.readFailure = errSecMissingEntitlement
        if case .failure(let error) = SyncStore.pull(using: keychain) {
            check(error.status == errSecMissingEntitlement, "read error preserved")
        } else { fatalError("read error treated as empty") }
        keychain.readFailure = nil; keychain.writeFailure = nil
        keychain.items["payload-v1"] = try JSONEncoder().encode(a)
        let legacy = try SyncStore.pull(using: keychain).get()
        check(legacy.snapshots.count == 3, "legacy payload remains readable")
        keychain.items["payload-v1"] = Data("invalid".utf8)
        if case .failure = SyncStore.pull(using: keychain) { check(true, "decode failure blocks publication") }
        else { fatalError("corrupt payload treated as empty") }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("yaoshi-sync-tests-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "yaoshi-sync-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let correctionDirectory = directory.appendingPathComponent("strength-correction")
        try fm.createDirectory(at: correctionDirectory, withIntermediateDirectories: true)
        let correctionSuite = "yaoshi-correction-" + UUID().uuidString
        let correctionDefaults = UserDefaults(suiteName: correctionSuite)!
        defer { correctionDefaults.removePersistentDomain(forName: correctionSuite) }
        var original = SyncPayload()
        var correctionLegacyDose = doseA; correctionLegacyDose.note = "保留备注"; correctionLegacyDose.food = .withFood
        var alreadyCorrect = doseB; alreadyCorrect.mg = 50
        var otherDrug = Dose(at: timestamp, mg: 40); otherDrug.med = "Other"
        let unselected = Dose(at: timestamp, mg: 40)
        original.doses = [correctionLegacyDose, alreadyCorrect, otherDrug, unselected]
        var oldSettings = SyncedSettings(); oldSettings.defaultMg = 40; oldSettings.updatedAt = timestamp
        original.settings = oldSettings; original.supply = stock
        original.tombstones["d:" + UUID().uuidString] = timestamp
        try JSONEncoder().encode(original).write(to: correctionDirectory.appendingPathComponent("durable-state.json"))
        let correctionStore = Store(directory: correctionDirectory, defaults: correctionDefaults, syncAutomatically: false)
        let selectedIDs: Set<UUID> = [correctionLegacyDose.id, alreadyCorrect.id, otherDrug.id]
        let correctionBlocker = correctionDirectory.appendingPathComponent("durable-state.json.tmp")
        try fm.createDirectory(at: correctionBlocker, withIntermediateDirectories: true)
        check(!correctionStore.correctLegacy40mgDoses(ids: selectedIDs), "failed correction checkpoint reports failure")
        check(correctionStore.doses.first { $0.id == correctionLegacyDose.id }?.mg == 40 && correctionStore.settings.defaultMg == 40,
              "failed correction checkpoint preserves visible dose and settings")
        try? fm.removeItem(at: correctionBlocker)
        check(correctionStore.correctLegacy40mgDoses(ids: selectedIDs), "explicit legacy correction persists")
        let correctedDose = correctionStore.doses.first { $0.id == correctionLegacyDose.id }!
        check(correctedDose.mg == 50 && correctedDose.at == correctionLegacyDose.at && correctedDose.note == correctionLegacyDose.note &&
              correctedDose.food == correctionLegacyDose.food && correctedDose.updatedAt! > correctionLegacyDose.updatedAt!,
              "correction preserves identity details and advances revision")
        check(correctionStore.doses.first { $0.id == alreadyCorrect.id } == alreadyCorrect &&
              correctionStore.doses.first { $0.id == otherDrug.id } == otherDrug &&
              correctionStore.doses.first { $0.id == unselected.id } == unselected,
              "correction preserves already-correct other-drug and unselected records")
        check(correctionStore.settings.defaultMg == 50 && correctionStore.supply == stock && correctionStore.tombstones == original.tombstones,
              "correction updates legacy default while preserving stock and deletions")
        let originalBackupURL = correctionDirectory.appendingPathComponent("before-40-to-50-correction.json")
        let originalBackupData = try Data(contentsOf: originalBackupURL)
        let originalBackup = try JSONDecoder().decode(SyncPayload.self, from: originalBackupData)
        check(originalBackup.doses.first { $0.id == correctionLegacyDose.id }?.mg == 40 && originalBackup.settings?.defaultMg == 40,
              "independent backup preserves pre-correction dose and settings")
        check(correctionStore.correctLegacy40mgDoses(ids: selectedIDs) &&
              correctionStore.doses.first { $0.id == correctionLegacyDose.id } == correctedDose,
              "repeated correction is idempotent")
        let backupAfterRetry = try Data(contentsOf: originalBackupURL)
        check(backupAfterRetry == originalBackupData, "original correction backup is never overwritten")
        let correctionReload = Store(directory: correctionDirectory, defaults: correctionDefaults, syncAutomatically: false)
        check(correctionReload.doses.first { $0.id == correctionLegacyDose.id } == correctedDose && correctionReload.settings.defaultMg == 50,
              "historical correction survives restart")
        let correctionCloud = FakeKeychain()
        check(SyncStore.push(original, using: correctionCloud, account: "payload-v2-stale-strength").isOK,
              "stale correction test snapshot publishes")
        correctionReload.sync(using: correctionCloud)
        check(correctionReload.doses.first { $0.id == correctionLegacyDose.id } == correctedDose && correctionReload.settings.defaultMg == 50,
              "stale cloud snapshot cannot undo explicit correction")

        let store = Store(directory: directory, defaults: defaults, syncAutomatically: false)
        var supply = Supply(); supply.pillsLeft = 10; store.updateSupply(supply)
        let eventID = UUID()
        check(store.acceptWatchDose(id: eventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "watch receipt persists")
        check(store.acceptWatchDose(id: eventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "watch ACK loss retransmission accepted")
        check(store.doses.count == 1 && store.supply.pillsLeft == 10, "retransmission does not double count or decrement")
        check(!store.acceptWatchDose(id: eventID, at: timestamp, mg: 50, med: "Test", recordedAt: timestamp), "same UUID conflicting event not acknowledged")
        var edited = store.doses[0]; edited.mg = 60; store.update(edited)
        check(store.acceptWatchDose(id: eventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "later explicit phone edit preserved")
        check(store.doses[0].mg == 60, "retransmit preserves later phone edit")
        store.delete(store.doses[0])
        check(store.acceptWatchDose(id: eventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "deleted watch event acknowledged from durable tombstone")
        check(store.doses.isEmpty && store.supply.pillsLeft == 10, "deleted event not resurrected")

        let blocker = directory.appendingPathComponent("durable-state.json.tmp")
        try fm.createDirectory(at: blocker, withIntermediateDirectories: true)
        let failedEventID = UUID()
        check(!store.acceptWatchDose(id: failedEventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "disk failure prevents watch ACK")
        try fm.createDirectory(at: blocker, withIntermediateDirectories: true)
        let transport = FakeKeychain()
        store.sync(using: transport)
        check(transport.items.isEmpty && transport.updates == 0 && transport.adds == 0, "unchanged memory after disk failure cannot publish ACK")
        try? fm.removeItem(at: blocker)
        check(store.acceptWatchDose(id: failedEventID, at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "disk recovery replays pending watch transaction")
        check(store.doses.count == 1 && store.supply.pillsLeft == 10, "pending replay preserves paused inventory")
        store.sync(using: transport)
        check(transport.items.count == 1, "repaired storage can publish")

        // Simulate one split data file missing after a crash; full checkpoint restores it.
        try fm.removeItem(at: directory.appendingPathComponent("doses.json"))
        try? fm.removeItem(at: directory.appendingPathComponent("doses.json.bak"))
        let reloaded = Store(directory: directory, defaults: defaults, syncAutomatically: false)
        check(reloaded.doses.count == 1 && reloaded.supply.pillsLeft == 10, "full checkpoint restores partial split-file failure")
        let sequentialDirectory = directory.appendingPathComponent("sequential")
        try fm.createDirectory(at: sequentialDirectory, withIntermediateDirectories: true)
        let sequentialStore = Store(directory: sequentialDirectory, defaults: defaults, syncAutomatically: false)
        var initialStock = Supply(); initialStock.pillsLeft = 10
        sequentialStore.updateSupply(initialStock)
        check(sequentialStore.acceptWatchDose(id: UUID(), at: timestamp, mg: 40, med: "Test", recordedAt: timestamp), "first sequential watch import")
        check(sequentialStore.acceptWatchDose(id: UUID(), at: timestamp.addingTimeInterval(5), mg: 40, med: "Test", recordedAt: timestamp.addingTimeInterval(5)), "second sequential watch import")
        check(!sequentialStore.inventoryNeedsReview && sequentialStore.supply.pillsLeft == 10, "causal watch imports preserve paused inventory")
        sequentialStore.inventorySync.conflictAt = Date()
        check(sequentialStore.inventoryNeedsReview, "inventory review remains visible")
        sequentialStore.updateSupply(sequentialStore.supply, resolvesConflict: true)
        check(!sequentialStore.inventoryNeedsReview, "explicit stock confirmation clears review")
        let reviewedReload = Store(directory: sequentialDirectory, defaults: defaults, syncAutomatically: false)
        check(!reviewedReload.inventoryNeedsReview, "inventory resolution persists across reload")
        let noteDirectory = directory.appendingPathComponent("notes")
        try fm.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let noteSuite = "yaoshi-note-tests-" + UUID().uuidString
        let noteDefaults = UserDefaults(suiteName: noteSuite)!
        defer { noteDefaults.removePersistentDomain(forName: noteSuite) }
        let notes = Store(directory: noteDirectory, defaults: noteDefaults, syncAutomatically: false)
        var noteSupply = Supply(); noteSupply.pillsLeft = 12
        notes.updateSupply(noteSupply)
        var firstNote = EffectLog(at: timestamp)
        firstNote.note = "现在心情轻松，做事情也很专注。"
        check(notes.saveEffect(firstNote), "standalone feeling note saves without a dose")
        check(notes.effects.first?.doseID == nil && notes.doses.isEmpty && notes.supply.pillsLeft == 12,
              "note does not create dose or change inventory")
        let noteDose = notes.quickTake(at: timestamp.addingTimeInterval(60))
        check(noteDose.pillCount == 1, "quick add records one actual pill")
        var secondNote = EffectLog(at: timestamp.addingTimeInterval(3600))
        secondNote.note = "药效挺好，记下此刻。"
        check(notes.saveEffect(secondNote), "second same-day note saves independently")
        check(notes.effects.count == 2 && notes.effects.last?.doseID == noteDose.id,
              "notes keep separate timestamps and associate preceding dose")
        firstNote.note = "编辑后的感受，保留原始时刻。"
        check(notes.update(firstNote), "existing feeling note can be edited")
        check(notes.effects.count == 2 && notes.effects.first?.note == firstNote.note && notes.effects.first?.at == timestamp,
              "editing does not duplicate or reset note time")
        let reloadedNotes = Store(directory: noteDirectory, defaults: noteDefaults, syncAutomatically: false)
        check(reloadedNotes.doses.first?.pillCount == 1, "actual pill count survives store reload")
        check(reloadedNotes.effects.count == 2 && reloadedNotes.effects.first?.note == firstNote.note,
              "feeling notes survive restart")
        check(reloadedNotes.doses.count == 1 && reloadedNotes.supply.pillsLeft == 12,
              "note save/edit/reload preserve medication totals")

        let watchNoteID = UUID()
        check(notes.acceptWatchNote(id: watchNoteID, at: timestamp, note: "手表记下的感受", recordedAt: timestamp),
              "watch feeling note is durably accepted")
        check(notes.acceptWatchNote(id: watchNoteID, at: timestamp, note: "手表记下的感受", recordedAt: timestamp),
              "watch note retransmission is acknowledged")
        check(notes.effects.count == 3 && notes.doses.count == 1 && notes.supply.pillsLeft == 12,
              "watch note duplicate does not duplicate notes or affect medication")
        check(!notes.acceptWatchNote(id: watchNoteID, at: timestamp, note: "UUID 冲突的另一条内容", recordedAt: timestamp),
              "same UUID with conflicting watch note is not acknowledged")
        var revisedWatchNote = notes.effects.first { $0.id == watchNoteID }!
        revisedWatchNote.note = "在手机上补充了感受"
        check(notes.update(revisedWatchNote), "watch note can be edited on phone")
        check(notes.acceptWatchNote(id: watchNoteID, at: timestamp, note: "手表记下的感受", recordedAt: timestamp),
              "watch retransmission respects later phone edit")
        check(notes.effects.first { $0.id == watchNoteID }?.note == revisedWatchNote.note,
              "later phone note text stays intact")
        check(notes.delete(revisedWatchNote), "note deletion is durable")
        check(notes.acceptWatchNote(id: watchNoteID, at: timestamp, note: "手表记下的感受", recordedAt: timestamp),
              "deleted watch note is acknowledged from tombstone")
        check(notes.effects.count == 2, "deleted note is not resurrected by retransmission")
        check(!notes.acceptWatchNote(id: UUID(), at: timestamp, note: " \n ", recordedAt: timestamp),
              "blank watch note is rejected")
        check(!notes.acceptWatchNote(id: UUID(), at: timestamp, note: String(repeating: "感", count: 501), recordedAt: timestamp),
              "oversized watch note is rejected")

        var diskFailureNote = EffectLog(at: timestamp)
        diskFailureNote.note = "暂时写不进去也不能丢草稿"
        let noteBlocker = noteDirectory.appendingPathComponent("durable-state.json.tmp")
        try fm.createDirectory(at: noteBlocker, withIntermediateDirectories: true)
        check(!notes.saveEffect(diskFailureNote), "disk failure prevents note save success")
        check(!notes.effects.contains { $0.id == diskFailureNote.id }, "failed save does not show uncommitted note")
        try? fm.removeItem(at: noteBlocker)
        check(notes.saveEffect(diskFailureNote), "same note can be retried after storage recovers")
        try fm.removeItem(at: noteDirectory.appendingPathComponent("effects.json"))
        try? fm.removeItem(at: noteDirectory.appendingPathComponent("effects.json.bak"))
        let recoveredNotes = Store(directory: noteDirectory, defaults: noteDefaults, syncAutomatically: false)
        check(recoveredNotes.effects.count == 3 && recoveredNotes.effects.contains { $0.id == diskFailureNote.id },
              "full checkpoint recovers missing notes file")

        var phoneNotes = SyncPayload(); phoneNotes.effects = recoveredNotes.effects
        phoneNotes.tombstones = recoveredNotes.tombstones
        var otherNotes = SyncPayload()
        var independentNote = EffectLog(at: timestamp); independentNote.note = "另一台手机独立记录"
        independentNote.updatedAt = timestamp
        otherNotes.effects = [independentNote]
        let mergedNotes = SyncMerge.merge(local: phoneNotes, remote: otherNotes)
        check(mergedNotes.effects.count == 4, "independent offline notes merge without loss")
        check(SyncStore.fingerprint(mergedNotes) == SyncStore.fingerprint(SyncMerge.merge(local: otherNotes, remote: phoneNotes)),
              "note sync converges in both directions")
        var staleWatchNote = EffectLog(at: timestamp); staleWatchNote.id = watchNoteID
        staleWatchNote.note = "手表记下的感受"; staleWatchNote.updatedAt = timestamp
        otherNotes.effects.append(staleWatchNote)
        check(!SyncMerge.merge(local: phoneNotes, remote: otherNotes).effects.contains { $0.id == watchNoteID },
              "note deletion wins against an old offline snapshot")
        // Old snapshots have no lifeEvents key. Upgrade preserves all existing records.
        var oldPayload = a
        oldPayload.effects = [independentNote]
        oldPayload.days = [DayLog(date: DateOnly(timestamp))]
        oldPayload.supply = stock
        let oldData = try JSONEncoder().encode(oldPayload)
        let oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        check(oldObject["lifeEvents"] == nil, "empty life events retain legacy snapshot shape")
        let migrated = try JSONDecoder().decode(SyncPayload.self, from: oldData)
        check(migrated.lifeEvents.isEmpty && migrated.doses == oldPayload.doses &&
              migrated.effects == oldPayload.effects && migrated.days == oldPayload.days &&
              migrated.supply == oldPayload.supply && migrated.settings == oldPayload.settings,
              "legacy snapshot decodes without losing previous data")

        // The episode anchor is independently synchronized, so old clients changing
        // ordinary settings or doses cannot erase it by omitting an unknown field.
        check(oldObject["doseEpisode"] == nil && migrated.doseEpisode == nil,
              "legacy snapshots without an episode selection retain their original JSON shape")
        check(SyncStore.fingerprint(migrated) == SyncStore.fingerprint(oldPayload),
              "decoding a legacy snapshot does not change its canonical content")
        let firstSelection = DoseEpisodeSelection(doseID: doseA.id, updatedAt: timestamp)
        var episodeA = a; episodeA.doseEpisode = firstSelection
        var episodeB = b
        var laterSettings = settings; laterSettings.defaultMg = 60
        laterSettings.updatedAt = timestamp.addingTimeInterval(30)
        episodeB.settings = laterSettings
        let episodeMerged = SyncMerge.merge(local: episodeA, remote: episodeB)
        check(episodeMerged.doseEpisode?.doseID == doseA.id && episodeMerged.settings?.defaultMg == 60 &&
              episodeMerged.doses.count == 2,
              "independent dose and settings changes preserve the explicit episode selection")
        check(SyncStore.fingerprint(episodeMerged) == SyncStore.fingerprint(SyncMerge.merge(local: episodeB, remote: episodeA)),
              "episode merge is symmetric when a peer has no selection field")
        check(SyncStore.fingerprint(episodeA) != SyncStore.fingerprint(a),
              "episode selection contributes to synchronization fingerprints")
        var changedEpisode = episodeA
        changedEpisode.doseEpisode = DoseEpisodeSelection(doseID: doseB.id, updatedAt: timestamp.addingTimeInterval(5))
        check(SyncMerge.merge(local: episodeA, remote: changedEpisode).doseEpisode?.doseID == doseB.id,
              "a newer explicit episode selection wins")
        var simultaneousEpisode = changedEpisode
        simultaneousEpisode.doseEpisode = DoseEpisodeSelection(doseID: doseA.id, updatedAt: timestamp.addingTimeInterval(5))
        check(SyncStore.fingerprint(SyncMerge.merge(local: changedEpisode, remote: simultaneousEpisode)) ==
              SyncStore.fingerprint(SyncMerge.merge(local: simultaneousEpisode, remote: changedEpisode)),
              "equal-time episode selections converge in either merge direction")
        var clearedEpisode = changedEpisode
        clearedEpisode.doseEpisode = DoseEpisodeSelection(doseID: nil, updatedAt: timestamp.addingTimeInterval(10))
        let clearedMerge = SyncMerge.merge(local: episodeA, remote: clearedEpisode)
        check(clearedMerge.doseEpisode != nil && clearedMerge.doseEpisode?.doseID == nil,
              "explicit clear retains its revision and beats an older selection")
        check(SyncMerge.merge(local: clearedMerge, remote: changedEpisode).doseEpisode?.doseID == nil,
              "an offline older selection cannot undo a newer clear")
        var onlySelection = SyncPayload(); onlySelection.doseEpisode = firstSelection
        check(!onlySelection.isEmpty, "episode selection alone is meaningful synchronized content")
        let episodeTransport = FakeKeychain()
        check(SyncStore.push(episodeMerged, using: episodeTransport, account: "payload-v2-episode-peer").isOK,
              "episode selection publishes through compressed transport")
        let transportedEpisode = try SyncStore.pull(using: episodeTransport).get().snapshots["payload-v2-episode-peer"]
        check(transportedEpisode?.doseEpisode?.doseID == doseA.id &&
              transportedEpisode?.doseEpisode?.updatedAt == timestamp,
              "episode selection and revision survive transport encoding")

        var snack = LifeEvent(at: timestamp, kind: .food, note: "只吃了一口也记下")
        snack.updatedAt = timestamp
        var sleep = LifeEvent(at: timestamp.addingTimeInterval(600), kind: .sleep)
        sleep.updatedAt = timestamp
        var wake = LifeEvent(at: timestamp.addingTimeInterval(3600), kind: .wake)
        wake.updatedAt = timestamp
        var lifeA = SyncPayload(); lifeA.lifeEvents = [snack]
        var lifeB = SyncPayload(); lifeB.lifeEvents = [wake, sleep]
        check(!lifeA.isEmpty, "life events alone make a nonempty snapshot")
        let combinedLife = SyncMerge.merge(local: lifeA, remote: lifeB)
        check(combinedLife.lifeEvents.count == 3, "independent offline food sleep and wake events survive merge")
        check(SyncStore.fingerprint(combinedLife) == SyncStore.fingerprint(SyncMerge.merge(local: lifeB, remote: lifeA)),
              "life event merge is symmetric")
        var lifeReordered = combinedLife; lifeReordered.lifeEvents.reverse()
        check(SyncStore.fingerprint(combinedLife) == SyncStore.fingerprint(lifeReordered),
              "life event fingerprint ignores ordering")
        check(SyncStore.fingerprint(lifeA) != SyncStore.fingerprint(SyncPayload()),
              "life events affect crossdevice content hash")
        var lifeEdit = lifeA
        lifeEdit.lifeEvents[0].note = "补充具体吃了什么"
        lifeEdit.lifeEvents[0].updatedAt = timestamp.addingTimeInterval(10)
        check(SyncMerge.merge(local: lifeA, remote: lifeEdit).lifeEvents == lifeEdit.lifeEvents,
              "later life event edit wins")
        var lifeConflict = lifeEdit; lifeConflict.lifeEvents[0].note = "同一修改时刻的另一台记录"
        check(SyncStore.fingerprint(SyncMerge.merge(local: lifeEdit, remote: lifeConflict)) ==
              SyncStore.fingerprint(SyncMerge.merge(local: lifeConflict, remote: lifeEdit)),
              "same-time life event conflicts converge")
        var lifeDeleted = SyncPayload()
        lifeDeleted.tombstones[snack.syncKey] = timestamp.addingTimeInterval(20)
        check(SyncMerge.merge(local: lifeEdit, remote: lifeDeleted).lifeEvents.isEmpty,
              "life event tombstones remove older offline copies")
        let lifeTransport = FakeKeychain()
        check(SyncStore.push(combinedLife, using: lifeTransport, account: "payload-v2-life-peer").isOK,
              "life events publish through compressed iCloud transport")
        let readLife = try SyncStore.pull(using: lifeTransport).get()
        check(readLife.snapshots["payload-v2-life-peer"]?.lifeEvents == combinedLife.lifeEvents,
              "life events survive transport encode decode")

        let lifeDirectory = directory.appendingPathComponent("life-events")
        try fm.createDirectory(at: lifeDirectory, withIntermediateDirectories: true)
        let lifeSuite = "yaoshi-life-tests-" + UUID().uuidString
        let lifeDefaults = UserDefaults(suiteName: lifeSuite)!
        defer { lifeDefaults.removePersistentDomain(forName: lifeSuite) }
        let lifeStore = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        var ordinaryNote = EffectLog(at: timestamp); ordinaryNote.note = "刚吃了东西、准备睡觉"
        check(lifeStore.saveEffect(ordinaryNote), "ordinary note saves alongside life events")
        let ordinaryDose = lifeStore.quickTake(at: timestamp)
        check(lifeStore.lifeEvents.isEmpty, "notes and doses never infer food or sleep events")
        check(lifeStore.saveLifeEvent(snack) && lifeStore.saveLifeEvent(sleep) && lifeStore.saveLifeEvent(wake),
              "all three explicit life event kinds save durably")
        check(lifeStore.doses.map(\.id) == [ordinaryDose.id] && lifeStore.effects.count == 1 &&
              lifeStore.supply == Supply(), "food and sleep events preserve dose note and inventory data")
        var savedSnack = lifeStore.lifeEvents.first { $0.id == snack.id }!
        savedSnack.at = timestamp.addingTimeInterval(-60)
        savedSnack.note = "修正吃东西的时刻"
        check(lifeStore.saveLifeEvent(savedSnack) && lifeStore.lifeEvents.count == 3,
              "life event edits retain UUID without duplicate rows")
        let lifeReload = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        check(lifeReload.lifeEvents.first { $0.id == snack.id }?.at == savedSnack.at &&
              lifeReload.lifeEvents.first { $0.id == snack.id }?.note == savedSnack.note,
              "life event time and note edits survive restart")
        check(lifeDefaults.integer(forKey: "lastLifeEventCount") == 3,
              "durable life event count is tracked")

        let lifeBlocker = lifeDirectory.appendingPathComponent("durable-state.json.tmp")
        let unsavedMeal = LifeEvent(at: timestamp.addingTimeInterval(8000), kind: .food)
        try fm.createDirectory(at: lifeBlocker, withIntermediateDirectories: true)
        check(!lifeStore.saveLifeEvent(unsavedMeal) && !lifeStore.lifeEvents.contains { $0.id == unsavedMeal.id },
              "failed life event creation leaves timer inputs unchanged")
        var failedEdit = savedSnack; failedEdit.at = timestamp.addingTimeInterval(9000)
        try fm.createDirectory(at: lifeBlocker, withIntermediateDirectories: true)
        check(!lifeStore.saveLifeEvent(failedEdit) && lifeStore.lifeEvents.first { $0.id == snack.id }?.at == savedSnack.at,
              "failed life event edit preserves last saved time")
        try fm.createDirectory(at: lifeBlocker, withIntermediateDirectories: true)
        check(!lifeStore.delete(savedSnack) && lifeStore.lifeEvents.contains { $0.id == snack.id } &&
              lifeStore.tombstones[snack.syncKey] == nil,
              "failed life event delete preserves row and tombstones")
        try? fm.removeItem(at: lifeBlocker)
        check(lifeStore.delete(savedSnack), "life event delete saves durably")
        let afterDelete = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        check(afterDelete.lifeEvents.count == 2 && afterDelete.tombstones[snack.syncKey] != nil,
              "life event deletion and tombstone survive restart")

        // A missing split file is repaired from the complete checkpoint.
        try fm.removeItem(at: lifeDirectory.appendingPathComponent("life-events.json"))
        try? fm.removeItem(at: lifeDirectory.appendingPathComponent("life-events.json.bak"))
        try fm.removeItem(at: lifeDirectory.appendingPathComponent("effects.json"))
        try? fm.removeItem(at: lifeDirectory.appendingPathComponent("effects.json.bak"))
        let checkpointBeforeRecovery = try Data(contentsOf: lifeDirectory.appendingPathComponent("durable-state.json"))
        try fm.createDirectory(at: lifeBlocker, withIntermediateDirectories: true)
        let readOnlyRecovery = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        check(readOnlyRecovery.lifeEvents.count == 2 && readOnlyRecovery.effects.map(\.id) == [ordinaryNote.id] &&
              !readOnlyRecovery.lifeEvents.contains { $0.id == snack.id },
              "already durable events and notes remain visible when restart repair cannot write")
        check(!readOnlyRecovery.storageOK && readOnlyRecovery.tombstones[snack.syncKey] != nil,
              "read-only recovery preserves deletion and reports repair failure")
        let checkpointAfterRecovery = try Data(contentsOf: lifeDirectory.appendingPathComponent("durable-state.json"))
        check(checkpointBeforeRecovery == checkpointAfterRecovery,
              "failed startup repair leaves the valid persisted checkpoint intact")
        try? fm.removeItem(at: lifeBlocker)
        let lifeRecovered = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        check(lifeRecovered.lifeEvents.count == 2 && !lifeRecovered.lifeEvents.contains { $0.id == snack.id },
              "checkpoint restores life events without resurrecting deleted event")
        lifeRecovered.sync(using: lifeTransport)
        check(lifeRecovered.lifeEvents.count == 2 && !lifeRecovered.lifeEvents.contains { $0.id == snack.id },
              "Store sync merges peer life events and retains local deletion")
        var remoteOnly = LifeEvent(at: timestamp.addingTimeInterval(10000), kind: .food)
        remoteOnly.updatedAt = timestamp
        var remoteNew = combinedLife; remoteNew.lifeEvents.append(remoteOnly)
        check(SyncStore.push(remoteNew, using: lifeTransport, account: "payload-v2-life-peer").isOK,
              "peer publishes a later independent life event")
        try fm.createDirectory(at: lifeBlocker, withIntermediateDirectories: true)
        let writesBeforeFailedMerge = lifeTransport.updates + lifeTransport.adds
        lifeRecovered.sync(using: lifeTransport)
        check(!lifeRecovered.lifeEvents.contains { $0.id == remoteOnly.id } &&
              lifeTransport.updates + lifeTransport.adds == writesBeforeFailedMerge,
              "failed incoming life event checkpoint changes neither UI nor cloud acknowledgement")
        try? fm.removeItem(at: lifeBlocker)
        lifeRecovered.sync(using: lifeTransport)
        check(lifeRecovered.lifeEvents.contains { $0.id == remoteOnly.id },
              "incoming life event merge retries after disk recovery")

        // Episode selection is saved before the displayed start changes, survives
        // restarts, and can be independently cleared without deleting user records.
        let episodeDirectory = directory.appendingPathComponent("episodes")
        try fm.createDirectory(at: episodeDirectory, withIntermediateDirectories: true)
        let episodeSuite = "yaoshi-episode-tests-" + UUID().uuidString
        let episodeDefaults = UserDefaults(suiteName: episodeSuite)!
        defer { episodeDefaults.removePersistentDomain(forName: episodeSuite) }
        let episodeStore = Store(directory: episodeDirectory, defaults: episodeDefaults, syncAutomatically: false)
        let episodeNow = timestamp.addingTimeInterval(96 * 3600)
        episodeStore.add(doseA); episodeStore.add(doseB)
        let episodeFuture = Dose(at: episodeNow.addingTimeInterval(3600), mg: 40)
        episodeStore.add(episodeFuture)
        var episodeNote = EffectLog(at: timestamp); episodeNote.note = "第一波的感受"
        check(episodeStore.saveEffect(episodeNote), "episode test note persists")
        check(episodeStore.doseEpisode == nil, "derived initial round does not invent a persisted manual selection")
        check(!episodeStore.selectDoseEpisode(startingAt: UUID(), now: episodeNow) && episodeStore.doseEpisode == nil,
              "unknown dose selection is rejected without altering the episode")
        check(!episodeStore.selectDoseEpisode(startingAt: episodeFuture.id, now: episodeNow) && episodeStore.doseEpisode == nil,
              "future dose selection is rejected without altering the episode")
        check(episodeStore.selectDoseEpisode(startingAt: doseA.id, now: episodeNow),
              "explicit episode selection saves durably")
        let selectedReload = Store(directory: episodeDirectory, defaults: episodeDefaults, syncAutomatically: false)
        check(selectedReload.doseEpisode?.doseID == doseA.id && selectedReload.doses.count == 3 &&
              selectedReload.effects.map(\.id) == [episodeNote.id] && selectedReload.supply == Supply(),
              "episode selection survives restart without altering doses notes or inventory")
        let extraDose = selectedReload.quickTake(at: episodeNow)
        // This persistence test deliberately spans 96 hours. Use a longer grouping
        // threshold so automatic gap rollover does not obscure anchor persistence.
        let continuedEpisode = DoseEpisode(doses: selectedReload.doses, selection: selectedReload.doseEpisode,
                                           now: episodeNow, newRoundGapHours: 120)
        check(continuedEpisode.start?.id == doseA.id && continuedEpisode.doses.map(\.id).contains(extraDose.id) &&
              episodeNow.timeIntervalSince(continuedEpisode.start!.at) == 96 * 3600,
              "a quick repeat dose preserves the start beyond the concentration window")
        let episodeBlocker = episodeDirectory.appendingPathComponent("durable-state.json.tmp")
        try fm.createDirectory(at: episodeBlocker, withIntermediateDirectories: true)
        check(!selectedReload.selectDoseEpisode(startingAt: doseB.id, now: episodeNow) &&
              selectedReload.doseEpisode?.doseID == doseA.id,
              "checkpoint failure prevents an unsaved episode start from reaching the UI")
        try fm.createDirectory(at: episodeBlocker, withIntermediateDirectories: true)
        check(!selectedReload.selectDoseEpisode(startingAt: nil, now: episodeNow) &&
              selectedReload.doseEpisode?.doseID == doseA.id,
              "checkpoint failure also preserves the selection when clearing")
        try? fm.removeItem(at: episodeBlocker)
        check(selectedReload.selectDoseEpisode(startingAt: doseB.id, now: episodeNow),
              "episode can be changed after disk recovery")
        let changedReload = Store(directory: episodeDirectory, defaults: episodeDefaults, syncAutomatically: false)
        check(changedReload.doseEpisode?.doseID == doseB.id,
              "changing the first dose survives restart")
        let episodeMirror = episodeDirectory.appendingPathComponent("dose-episode.json")
        try fm.removeItem(at: episodeMirror)
        try? fm.removeItem(at: episodeMirror.appendingPathExtension("bak"))
        let episodeRecovered = Store(directory: episodeDirectory, defaults: episodeDefaults, syncAutomatically: false)
        check(episodeRecovered.doseEpisode?.doseID == doseB.id,
              "complete checkpoint repairs a lost episode selection mirror")
        episodeRecovered.delete(doseB)
        check(episodeRecovered.doseEpisode?.doseID == doseB.id &&
              DoseEpisode(doses: episodeRecovered.doses, selection: episodeRecovered.doseEpisode,
                          now: episodeNow, newRoundGapHours: 120).start == nil,
              "deleting the first dose invalidates the anchor instead of silently choosing another")
        check(episodeRecovered.selectDoseEpisode(startingAt: nil, now: episodeNow), "episode selection can be cleared explicitly")
        let clearedReload = Store(directory: episodeDirectory, defaults: episodeDefaults, syncAutomatically: false)
        check(clearedReload.doseEpisode != nil && clearedReload.doseEpisode?.doseID == nil &&
              clearedReload.doses.count == 3 && clearedReload.effects.count == 1,
              "a cleared episode revision survives restart while all remaining records are retained")

        check(selectedReload.activeStack(at: episodeNow).contains { $0.id == doseA.id },
              "store supplies doses older than 48 hours to the concentration model")
        check(!selectedReload.activeStack(at: episodeNow).contains { $0.id == episodeFuture.id },
              "store excludes future records from current model predictions")

        // If every copy is lost, the persisted count must surface a storage error.
        for name in ["life-events.json", "life-events.json.bak", "durable-state.json", "durable-state.json.bak"] {
            try? fm.removeItem(at: lifeDirectory.appendingPathComponent(name))
        }
        let lostLife = Store(directory: lifeDirectory, defaults: lifeDefaults, syncAutomatically: false)
        check(!lostLife.storageOK && lostLife.storageMessage.contains("进食与睡眠记录条数异常"),
              "missing life records trigger the durable count guard")
        print("PASS: \(passed) sync, episode, feeling-note, food/sleep and durable watch regression checks")
    }
}
