import Foundation

@main struct DoseEpisodeTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Dose(at: now.addingTimeInterval(-96 * 3600), mg: 40)
        let repeated = Dose(at: now.addingTimeInterval(-50 * 3600), mg: 40)
        let increased = Dose(at: now.addingTimeInterval(-2 * 3600), mg: 60)
        let earlier = Dose(at: first.at.addingTimeInterval(-3600), mg: 40)
        let future = Dose(at: now.addingTimeInterval(3600), mg: 40)
        let selection = DoseEpisodeSelection(doseID: first.id, updatedAt: now)
        let records = [increased, future, earlier, first, repeated]

        let unselected = DoseEpisode(doses: records, selection: nil, now: now)
        check(unselected.start?.id == earlier.id && unselected.doses.count == 4,
              "the first actual dose begins the initial round without manual selection")
        let empty = DoseEpisode(doses: [], selection: selection, now: now)
        check(empty.start == nil && empty.doses.isEmpty, "missing selected dose never invents a start")
        let cleared = DoseEpisode(doses: records,
                                  selection: DoseEpisodeSelection(doseID: nil, updatedAt: now), now: now)
        check(cleared.start == nil && cleared.doses.isEmpty, "explicitly cleared selection stays empty")
        let futureStart = DoseEpisode(doses: records,
                                      selection: DoseEpisodeSelection(doseID: future.id, updatedAt: now), now: now)
        check(futureStart.start == nil && futureStart.doses.isEmpty, "future dose cannot begin a current episode")

        let episode = DoseEpisode(doses: records, selection: selection, now: now)
        check(episode.start?.id == first.id, "repeat and increased doses retain the selected first dose")
        check(now.timeIntervalSince(episode.start!.at) == 96 * 3600,
              "elapsed time continues across days and the 48-hour concentration window")
        check(episode.doses.map(\.id) == [first.id, repeated.id, increased.id],
              "episode includes its real doses in time order and excludes earlier and future doses")
        check(DoseEpisode(doses: records.reversed(), selection: selection, now: now).doses == episode.doses,
              "unordered synchronization input gives the same episode")
        let another = Dose(at: now, mg: 80)
        let appended = DoseEpisode(doses: records + [another], selection: selection, now: now)
        check(appended.start?.id == first.id && appended.doses.count == 4,
              "recording another dose now adds to the episode without restarting it")

        let sameTime = Dose(at: first.at, mg: 20)
        let simultaneous = DoseEpisode(doses: records + [sameTime], selection: selection, now: now)
        check(simultaneous.start?.id == first.id && simultaneous.doses.count == 4,
              "separate doses at the selected timestamp are included without changing the anchor")
        check(DoseEpisode(doses: (records + [sameTime]).reversed(), selection: selection, now: now).doses == simultaneous.doses,
              "equal-time doses are ordered deterministically")

        var corrected = first
        corrected.at = now.addingTimeInterval(-72 * 3600)
        let edited = DoseEpisode(doses: records.filter { $0.id != first.id } + [corrected], selection: selection, now: now)
        check(edited.start?.at == corrected.at && now.timeIntervalSince(edited.start!.at) == 72 * 3600,
              "correcting the first dose time updates the elapsed time")
        let deleted = DoseEpisode(doses: records.filter { $0.id != first.id }, selection: selection, now: now)
        check(deleted.start == nil && deleted.doses.isEmpty,
              "deleting the selected dose requires reselection rather than falling back to another dose")
        let switched = DoseEpisode(doses: records,
                                   selection: DoseEpisodeSelection(doseID: increased.id, updatedAt: now), now: now)
        check(switched.start?.id == increased.id && switched.doses.map(\.id) == [increased.id],
              "explicitly selecting a later first dose starts a new episode")
        let rollover = DoseEpisode(doses: [first, another], selection: selection, now: now)
        check(rollover.start?.id == another.id && rollover.autoStarted,
              "a real gap exceeding the default 48 hours begins a new episode")
        let longGapSetting = DoseEpisode(doses: [first, another], selection: selection,
                                         now: now, newRoundGapHours: 120)
        check(longGapSetting.start?.id == first.id && !longGapSetting.autoStarted,
              "an explicitly longer gap setting preserves a 96 hour episode")
        let clearedAfterGap = DoseEpisode(doses: [first, another],
                                          selection: DoseEpisodeSelection(doseID: nil, updatedAt: now), now: now)
        check(clearedAfterGap.start == nil && clearedAfterGap.doses.isEmpty,
              "an explicitly cleared round stays cleared even when history contains a long gap")
        let initialSingle = DoseEpisode(doses: [another], selection: nil, now: now)
        check(initialSingle.start?.id == another.id && initialSingle.doses.count == 1,
              "a single first dose immediately starts a round")
        print("PASS: \(passed) dose episode timeline checks")
    }
}
