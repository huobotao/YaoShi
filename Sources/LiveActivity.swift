#if !targetEnvironment(macCatalyst)
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Bounded display-only model samples. Index 64 is exactly the evaluation time;
/// the two sides have independent time steps, not uniformly spaced x positions.
struct DoseActivityCurve: Codable, Hashable {
    var startAt: Date
    var endAt: Date
    var upperLevel: Double
    var samples: [Int]

    static let currentIndex = 64
    static let sampleCount = 97

    func isValid(at refreshedAt: Date) -> Bool {
        startAt.timeIntervalSinceReferenceDate.isFinite &&
        endAt.timeIntervalSinceReferenceDate.isFinite &&
        refreshedAt.timeIntervalSinceReferenceDate.isFinite &&
        startAt < refreshedAt && refreshedAt < endAt &&
        upperLevel.isFinite && upperLevel >= 1.15 &&
        samples.count == Self.sampleCount && samples.allSatisfy { (0...10_000).contains($0) }
    }

    func fraction(at date: Date) -> Double {
        date.timeIntervalSince(startAt) / endAt.timeIntervalSince(startAt)
    }

    func time(at index: Int, refreshedAt: Date) -> Date {
        let index = min(max(index, 0), Self.sampleCount - 1)
        if index == Self.currentIndex { return refreshedAt }
        if index <= Self.currentIndex {
            return startAt.addingTimeInterval(refreshedAt.timeIntervalSince(startAt) * Double(index) / Double(Self.currentIndex))
        }
        return refreshedAt.addingTimeInterval(endAt.timeIntervalSince(refreshedAt) * Double(index - Self.currentIndex) / 32)
    }

    static func make(doses: [Dose], now: Date, curve: PlasmaCurveConfiguration) -> Self? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let history = doses.filter { $0.at.timeIntervalSinceReferenceDate.isFinite && $0.at <= now && $0.mg > 0 }
        guard !history.isEmpty else { return nil }
        // Match the main chart's visible window, while retaining all history in the model.
        let historyLimit = now.addingTimeInterval(-72 * 3600)
        let earliest = history.filter { $0.at >= historyLimit }.map(\.at).min()
        let proposedStart = earliest?.addingTimeInterval(-3600) ?? now.addingTimeInterval(-16 * 3600)
        let start = max(historyLimit, min(now.addingTimeInterval(-4 * 3600), proposedStart))
        var result = Self(startAt: start, endAt: now.addingTimeInterval(12 * 3600), upperLevel: 1.15, samples: [])
        let levels = (0..<Self.sampleCount).map {
            DoseEngine.totalPlasma(history, at: result.time(at: $0, refreshedAt: now), curve: curve)
        }
        guard levels.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        result.upperLevel = max(1.15, (levels.max() ?? 0) * 1.12)
        guard result.upperLevel.isFinite else { return nil }
        result.samples = levels.map { min(10_000, max(0, Int(($0 / result.upperLevel * 10_000).rounded()))) }
        return result.isValid(at: now) ? result : nil
    }
}

/// 常驻的服药状态实时活动（锁屏 + 灵动岛）。
/// 主 App 与 Widget 扩展共用这个类型，字段全部是值类型且向后兼容。
struct DoseAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 上次服药时刻。为空表示还没有任何记录。
        var lastDoseAt: Date?
        var lastMg: Int
        /// 药效阶段（存字符串，避免以后加枚举值让旧活动解不出来）
        var phaseRaw: String
        /// 相对药效强度 0…1（画曲线用）
        var level: Double
        /// 剩余有效时间比例 0…1（进度条用）。旧版活动没有这个字段，解码为 nil。
        var remainingRaw: Double? = nil
        /// Total model concentration change per hour; absent on legacy activities.
        var plasmaSlopePerHour: Double? = nil

        var remaining: Double { remainingRaw ?? 0 }
        /// 高峰结束时刻
        var peakEndAt: Date?
        /// 药效结束时刻
        var effectEndAt: Date?
        /// 今天已服几次
        var takenToday: Int
        /// 今天的目标服药时刻
        var targetAt: Date?
        /// 今天被标记为不吃
        var skippedToday: Bool
        /// 还剩几粒
        var pillsLeft: Int
        /// Model snapshot only; stale values are explicitly labelled historical.
        var concentrationRatio: Double? = nil
        var predictedPeakAt: Date? = nil
        /// Resolved by Store using the original record identities and episode selection.
        /// Missing/explicitly cleared starts remain absent; never infer them from dose ticks.
        var episodeStartedAt: Date? = nil
        var curve: DoseActivityCurve? = nil
        var refreshedAt: Date

        /// An immutable prediction interval for the system-rendered countdown.
        /// It intentionally does not consult the wall clock or ActivityKit's stale flag:
        /// a concentration snapshot can expire while its known deadline still counts down.
        /// Native Text(timerInterval:countsDown:) clamps to zero at the upper bound.
        var predictedPeakTimerInterval: ClosedRange<Date>? {
            guard refreshedAt.timeIntervalSinceReferenceDate.isFinite,
                  let peak = predictedPeakAt,
                  peak.timeIntervalSinceReferenceDate.isFinite,
                  peak > refreshedAt else { return nil }
            return refreshedAt...peak
        }

        var phase: DosePhase { DosePhase(rawValue: phaseRaw) ?? .none }

        /// 按需记录，没有逾期服药状态；保留接口兼容旧活动。
        func overdue(at _: Date) -> Bool { false }
    }
    var title: String
}

#endif
