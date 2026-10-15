import Foundation

/// Preserve broad chart context while keeping the current and next 12 hours dense
/// enough for a watch readout. The phone remains the sole source of model values.
enum WatchCurveSampling {
    static func samples(start: Date, end: Date, now: Date, keyDates: [Date],
                        levelAt: (Date) -> Double) -> [WatchCurveSample] {
        guard end > start else { return [] }
        let span = end.timeIntervalSince(start)
        var dates = (0...180).map { start.addingTimeInterval(span * Double($0) / 180) }
        let denseStart = max(start, now.addingTimeInterval(-4 * 3600))
        let denseEnd = min(end, now.addingTimeInterval(12 * 3600))
        if denseEnd >= denseStart {
            var tick = denseStart
            while tick <= denseEnd {
                dates.append(tick)
                tick = tick.addingTimeInterval(5 * 60)
            }
            dates.append(denseEnd)
        }
        dates.append(now)
        dates.append(contentsOf: keyDates.filter { $0 >= start && $0 <= end })
        return Array(Set(dates)).sorted().map { WatchCurveSample(at: $0, level: levelAt($0)) }
    }
}
