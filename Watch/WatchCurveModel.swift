import Foundation

/// A deliberately local estimate from the dose summaries that Air R4 already
/// sends through WatchConnectivity. R4 does not send food or curve settings.
enum WatchCurveModel {
    struct Point {
        let at: Date
        let level: Double
    }

    private static let peakHours = 3.8
    private static let halfLifeHours = 10.5
    private static let lagHours = 0.5
    static let staleAfter: TimeInterval = 2 * 3600

    static func isStale(generatedAt: Date?, now: Date) -> Bool {
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > staleAfter
    }
    private static let elimination = log(2) / halfLifeHours
    private static let absorption: Double = {
        let wanted = peakHours - lagHours
        let ke = elimination
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
        return (low + high) / 2
    }()

    private static func shape(_ hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        if abs(absorption - elimination) < max(absorption, elimination) * 1e-8 {
            return hours * exp(-elimination * hours)
        }
        return abs(exp(-elimination * hours) - exp(-absorption * hours))
    }

    static func level(doses: [WatchDoseSummary], at date: Date) -> Double {
        let peak = shape(peakHours - lagHours)
        guard peak > 0 else { return 0 }
        return doses.reduce(0) { sum, dose in
            let hours = date.timeIntervalSince(dose.at) / 3600 - lagHours
            guard hours > 0 else { return sum }
            return sum + shape(hours) / peak * Double(dose.mg) / 50
        }
    }

    static func points(doses: [WatchDoseSummary], now: Date) -> [Point] {
        let start = now.addingTimeInterval(-18 * 3600)
        let span = 26.0 * 3600
        return (0...104).map { index in
            let date = start.addingTimeInterval(span * Double(index) / 104)
            return Point(at: date, level: level(doses: doses, at: date))
        }
    }
}
