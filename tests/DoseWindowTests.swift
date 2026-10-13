import Foundation

@main struct DoseWindowTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        passed += 1
    }
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func dose(_ hoursAgo: Double, mg: Int = 40, pills: Int? = nil) -> Dose {
            var value = Dose(at: now.addingTimeInterval(-hoursAgo * 3600), mg: mg)
            value.pillCount = pills
            return value
        }
        let left = dose(24, pills: 1)
        let right = dose(0, pills: 2)
        let inside = dose(12, pills: 1)
        let future = dose(-1, pills: 9)
        let records = [right, left, future, inside]
        let day = DoseWindowSummary(doses: records, end: now, durationHours: 24,
                                    mgPerPill: 40, now: now)
        check(day.recordedDoses.map(\.id) == [inside.id, right.id], "interval is (start, end], sorted, and excludes future records")
        check(day.totalPills == 3 && day.normalizedPills == 3 && day.doseCount == 2,
              "counts stored pills rather than number of administrations")
        check(day.totalMg == 80 && day.estimatedDoseCount == 0, "milligrams and explicit pill counts remain distinct")

        let previous = DoseWindowSummary(doses: records, end: day.start, durationHours: 24,
                                         mgPerPill: 40, now: now)
        check(previous.recordedDoses.map(\.id) == [left.id], "moving window back includes the former left boundary once")
        check(Set(day.recordedDoses.map(\.id)).isDisjoint(with: previous.recordedDoses.map(\.id)),
              "adjacent windows do not double count")
        let custom = DoseWindowSummary(doses: [dose(1, pills: 3), dose(35, pills: 2)],
                                       end: now, durationHours: 36, referenceHours: 12,
                                       mgPerPill: 40, now: now)
        check(close(custom.normalizedPills, 5.0 / 3.0), "custom 36 hour window normalizes to selected 12 hour reference")
        let week = DoseWindowSummary(doses: [dose(1, pills: 10)], end: now, durationHours: 168,
                                     mgPerPill: 40, now: now)
        check(close(week.normalizedPills, 10.0 / 7.0), "seven day window uses full duration even when only recent records exist")

        let mixed = DoseWindowSummary(doses: [dose(1, mg: 50, pills: 1), dose(2, mg: 60)],
                                      end: now, durationHours: 24, mgPerPill: 40, now: now)
        check(mixed.totalPills == 2.5 && mixed.estimatedDoseCount == 1,
              "legacy records use strength estimate while explicit historical counts retain their original quantity")
        let changedStrength = DoseWindowSummary(doses: [dose(1, mg: 50, pills: 1), dose(2, mg: 60)],
                                                end: now, durationHours: 24, mgPerPill: 20, now: now)
        check(changedStrength.totalPills == 4 && changedStrength.estimatedDoseCount == 1,
              "changing fallback strength changes only estimated records")
        let empty = DoseWindowSummary(doses: [], end: now, durationHours: 24, mgPerPill: 40, now: now)
        check(empty.totalPills == 0 && empty.normalizedPills == 0 && empty.recordedDoses.isEmpty,
              "empty recorded window produces zero counts without inventing records")
        let capped = DoseWindowSummary(doses: records, end: now.addingTimeInterval(7200), durationHours: 24,
                                       mgPerPill: 40, now: now)
        check(capped.end == now && capped.totalPills == day.totalPills, "future anchor is capped at now")

        let invalid = DoseWindowSummary(doses: [dose(1, mg: -40, pills: -1)], end: now,
                                        durationHours: .nan, referenceHours: -.infinity,
                                        mgPerPill: 0, now: now)
        check(invalid.durationHours == 24 && invalid.referenceHours == 24 && invalid.totalPills == 0,
              "invalid durations and negative doses cannot produce nonfinite or negative totals")
        let bounded = DoseWindowSummary(doses: [], end: now, durationHours: 0.5, referenceHours: 100_000,
                                        mgPerPill: 40, now: now)
        check(bounded.durationHours == 1 && bounded.referenceHours == 8760, "valid extreme durations are bounded")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let dstEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        let dst = DoseWindowSummary(doses: [], end: dstEnd, durationHours: 24, mgPerPill: 40, now: dstEnd)
        check(dst.end.timeIntervalSince(dst.start) == 86_400, "DST change preserves exact elapsed 24 hours")
        check(calendar.component(.hour, from: dst.start) == 11, "DST window start differs from same clock hour on previous calendar day")
        print("PASS: \(passed) rolling dose window checks")
    }
}
