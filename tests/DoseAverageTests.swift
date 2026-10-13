import Foundation

// Run: xcrun swiftc -parse-as-library Sources/Models.swift Sources/DoseAverageModel.swift tests/DoseAverageTests.swift -o /tmp/yaoshi-average-tests && /tmp/yaoshi-average-tests
@main struct DoseAverageTests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        guard value() else { fatalError("FAIL: " + description) }
        passed += 1
    }
    static func close(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-10
    }

    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hour: TimeInterval = 3600
        func summary(_ doses: [Dose], _ window: DoseAverageWindow = .day,
                     _ direction: DoseAverageDirection = .backward,
                     anchor: Date? = nil, strength: Int = 40) -> DoseAverageSummary {
            DoseAverageSummary(doses: doses, anchor: anchor ?? now, now: now,
                               window: window, direction: direction, mgPerPill: strength)
        }
        for window in DoseAverageWindow.allCases {
            let result = summary([Dose(at: now, mg: 80)], window)
            check(close(result.end.timeIntervalSince(result.start), Double(window.rawValue) * 86400), "fixed duration \(window)")
            check(close(result.totalPills, 2), "multiple pills \(window)")
            check(close(result.averagePer24Hours, 2 / Double(window.rawValue)), "full denominator \(window)")
            check(!result.hasRecordsBeforeWindow, "no earlier coverage \(window)")
        }
        let boundary = summary([
            Dose(at: now.addingTimeInterval(-24 * hour), mg: 400),
            Dose(at: now.addingTimeInterval(-24 * hour + 1), mg: 20),
            Dose(at: now, mg: 80),
            Dose(at: now.addingTimeInterval(1), mg: 400)
        ])
        check(close(boundary.totalPills, 2.5) && boundary.recordCount == 2, "start excluded; end included; future excluded")
        check(boundary.hasRecordsBeforeWindow, "record at start provides historical-span evidence")
        let adjacent = summary([Dose(at: now.addingTimeInterval(-24 * hour), mg: 40)], anchor: now.addingTimeInterval(-24 * hour))
        check(close(adjacent.totalPills, 1), "boundary belongs to exactly the earlier adjoining window")

        let centered = summary([Dose(at: now.addingTimeInterval(-24 * hour), mg: 40)], .day, .centered,
                               anchor: now.addingTimeInterval(-12 * hour))
        check(centered.start == now.addingTimeInterval(-24 * hour) && centered.end == now, "centered halves total one window")
        check(centered.averagePer24Hours == 0, "centered start is excluded")
        let futureCentered = summary([Dose(at: now, mg: 40)], .week, .centered)
        check(futureCentered.containsFuture && futureCentered.averagePer24Hours == nil, "future centered window suppresses average")
        check(close(futureCentered.totalPills, 1), "future window retains known actual total")
        let forward = summary([Dose(at: now.addingTimeInterval(hour), mg: 40)], .day, .forward)
        check(forward.start == now && forward.end == now.addingTimeInterval(24 * hour), "forward bounds")
        check(forward.averagePer24Hours == nil && forward.recordCount == 0, "future-dated dose is not actual")
        let pastForward = summary([Dose(at: now, mg: 40)], .day, .forward, anchor: now.addingTimeInterval(-24 * hour))
        check(close(pastForward.averagePer24Hours, 1) && !pastForward.containsFuture, "historical forward window can compute average")

        let invalid = summary([Dose(at: now, mg: -40), Dose(at: now, mg: 0), Dose(at: now, mg: 40),
                               Dose(at: now.addingTimeInterval(1), mg: -40),
                               Dose(at: now.addingTimeInterval(-25 * hour), mg: -40)])
        check(invalid.invalidDoseCount == 2 && invalid.recordCount == 1 && close(invalid.totalPills, 1), "invalid amounts excluded and scoped to elapsed window")
        for strength in [0, -40] {
            let result = summary([Dose(at: now, mg: 40)], strength: strength)
            check(!result.hasValidPillStrength && result.averagePer24Hours == nil && result.totalPills.isFinite, "invalid strength never divides by zero or returns average")
        }
        let fractional = summary([Dose(at: now, mg: 50)], strength: 40)
        check(close(fractional.totalPills, 1.25), "milligrams convert without integer rounding")
        let stored = summary([Dose(at: now, mg: 80, pillCount: 1)], strength: 50)
        check(close(stored.totalPills, 1) && stored.estimatedDoseCount == 0, "stored pill count survives current strength changes")
        let mixed = summary([Dose(at: now, mg: 80, pillCount: 1), Dose(at: now, mg: 50)], strength: 50)
        check(close(mixed.totalPills, 2) && mixed.estimatedDoseCount == 1, "legacy estimates identified separately from recorded counts")
        let empty = summary([], .week)
        check(empty.averagePer24Hours == 0 && empty.totalPills == 0 && empty.recordCount == 0 && !empty.hasRecordsBeforeWindow, "empty actual records return recorded zero with no span evidence")
        let recentOnly = summary([Dose(at: now.addingTimeInterval(-hour), mg: 40)], .week)
        check(close(recentOnly.averagePer24Hours, 1.0 / 7), "sparse recording does not shorten denominator")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        for components in [DateComponents(year: 2026, month: 10, day: 4, hour: 12),
                           DateComponents(year: 2026, month: 4, day: 5, hour: 12)] {
            let dstAnchor = calendar.date(from: components)!
            let result = DoseAverageSummary(doses: [], anchor: dstAnchor, now: dstAnchor,
                                            window: .day, direction: .backward, mgPerPill: 40)
            check(close(result.end.timeIntervalSince(result.start), 86400), "DST still uses exactly 24 elapsed hours")
            check(calendar.component(.hour, from: result.start) != 12, "DST fixture crosses clock change")
        }
        check(DoseAverageDirection.allCases.allSatisfy { !$0.label.isEmpty }, "all directions have labels")
        check(DoseAverageWindow.allCases.allSatisfy { !$0.label.isEmpty }, "all windows have labels")
        print("PASS: \(passed) dose average checks")
    }
}
