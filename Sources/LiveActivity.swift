#if !targetEnvironment(macCatalyst)
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

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
        var refreshedAt: Date

        var phase: DosePhase { DosePhase(rawValue: phaseRaw) ?? .none }

        /// 按需记录，没有逾期服药状态；保留接口兼容旧活动。
        func overdue(at _: Date) -> Bool { false }
    }
    var title: String
}

#endif
