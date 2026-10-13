import Foundation

// MARK: - 同步契约

/// 可跨设备同步的记录：唯一 id + 最后修改时刻
protocol SyncRecord {
    var id: UUID { get }
    var updatedAt: Date? { get set }
}

// MARK: - 只有年月日的日期类型

struct DateOnly: Codable, Hashable, Comparable, Identifiable {
    var y: Int, m: Int, d: Int
    var id: Int { y * 10000 + m * 100 + d }

    init(_ y: Int, _ m: Int, _ d: Int) { self.y = y; self.m = m; self.d = d }

    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    static func today() -> DateOnly { DateOnly(Date()) }

    var date: Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    var iso: String { String(format: "%04d-%02d-%02d", y, m, d) }
    var display: String { String(format: "%d月%d日", m, d) }
    var displayFull: String { String(format: "%d年%d月%d日", y, m, d) }

    var weekdayCN: String {
        let w = Calendar.current.component(.weekday, from: date)
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][w - 1]
    }

    func adding(days: Int) -> DateOnly {
        DateOnly(Calendar.current.date(byAdding: .day, value: days, to: date) ?? date)
    }

    /// 相差天数（self - other）
    func days(since other: DateOnly) -> Int {
        Calendar.current.dateComponents([.day], from: other.date, to: date).day ?? 0
    }

    static func < (a: DateOnly, b: DateOnly) -> Bool { a.id < b.id }
}

// MARK: - 服药记录

/// 为什么吃这一次。第一版给固定选项，可多选，也允许留空。
enum DoseReason: String, Codable, CaseIterable, Identifiable {
    case routine, study, exam, work, meeting, driving, social, chores, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .routine:  return "日常"
        case .study:    return "写作业"
        case .exam:     return "考试"
        case .work:     return "工作"
        case .meeting:  return "开会上课"
        case .driving:  return "开车"
        case .social:   return "社交"
        case .chores:   return "杂事家务"
        case .other:    return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .routine:  return "calendar"
        case .study:    return "pencil.and.outline"
        case .exam:     return "graduationcap.fill"
        case .work:     return "briefcase.fill"
        case .meeting:  return "person.2.fill"
        case .driving:  return "car.fill"
        case .social:   return "bubble.left.and.bubble.right.fill"
        case .chores:   return "house.fill"
        case .other:    return "ellipsis.circle"
        }
    }
}

/// 随餐情况会影响吸收速度，只记三档，允许不填
enum FoodState: String, Codable, CaseIterable, Hashable {
    case unknown, empty, withFood

    var label: String {
        switch self {
        case .unknown:  return "没记"
        case .empty:    return "空腹"
        case .withFood: return "随餐"
        }
    }
}

/// 一次服药
struct Dose: Codable, Identifiable, Hashable, SyncRecord {
    var id = UUID()
    var updatedAt: Date? = nil
    /// 服药时刻，精确到分钟
    var at: Date
    /// 剂量（毫克）
    var mg: Int = 40
    /// 实记颗数；旧的毫克记录缺少此字段时保持未知，不随当前每粒剂量变化。
    var pillCount: Int? = nil
    /// 药名。第一版固定 Vyvanse，留字段方便以后换药或加辅助药
    var med: String = "Vyvanse"
    /// 为什么吃，可多选，可为空
    var reasons: [DoseReason] = []
    var food: FoodState = .unknown
    var note: String = ""

    var dateOnly: DateOnly { DateOnly(at) }

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }

    /// 服药时刻是当天的第几个小时（带小数），做时间分布用
    var hourOfDay: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    var reasonText: String {
        reasons.isEmpty ? "" : reasons.map(\.label).joined(separator: "、")
    }
}

/// 可选的手动本轮起点；自动间隔分波可覆盖较旧的手动值。清空也保留修改时间，避免旧设备恢复旧起点。
struct DoseEpisodeSelection: Codable, Hashable {
    var doseID: UUID?
    var updatedAt: Date
}

// MARK: - 效果记录

/// 兴奋剂常见的可自察副作用。只记有没有，不做医学判断。
enum SideEffect: String, Codable, CaseIterable, Identifiable {
    case appetiteLoss, insomnia, palpitation, dryMouth, anxiety
    case flat, headache, irritable, nausea, sweating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appetiteLoss: return "没胃口"
        case .insomnia:     return "睡不着"
        case .palpitation:  return "心慌心悸"
        case .dryMouth:     return "口干"
        case .anxiety:      return "焦虑紧张"
        case .flat:         return "情绪平淡"
        case .headache:     return "头痛"
        case .irritable:    return "烦躁易怒"
        case .nausea:       return "反胃"
        case .sweating:     return "出汗"
        }
    }
}

/// 一次效果反馈。可以在服药后任意时刻记，也可以一天记好几次。
struct EffectLog: Codable, Identifiable, Hashable, SyncRecord {
    var id = UUID()
    var updatedAt: Date? = nil
    var at: Date
    /// 关联哪一次服药（找不到就是 nil，仍然有效）
    var doseID: UUID? = nil
    /// 专注程度 1-5，0 表示没评
    var focus: Int = 0
    /// 情绪状态 1-5
    var mood: Int = 0
    /// 这段时间出现的副作用
    var sides: [SideEffect] = []
    var note: String = ""

    /// 纯文字感受和原有评分共用存储与同步；不需要迁移历史记录。
    var isNoteOnly: Bool { focus == 0 && mood == 0 && sides.isEmpty }

    var dateOnly: DateOnly { DateOnly(at) }

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}

// MARK: - 进食与睡眠事件

/// 仅记录用户明确记下的事件；任何量的进食都可以单独记一次。
enum LifeEventKind: String, Codable, CaseIterable, Identifiable {
    case food, sleep, wake

    var id: String { rawValue }
    var label: String {
        switch self {
        case .food: return "吃东西"
        case .sleep: return "睡觉"
        case .wake: return "醒来"
        }
    }
    var symbol: String {
        switch self {
        case .food: return "fork.knife"
        case .sleep: return "bed.double.fill"
        case .wake: return "sun.max.fill"
        }
    }
}

struct LifeEvent: Codable, Identifiable, Hashable, SyncRecord {
    var id = UUID()
    var updatedAt: Date? = nil
    var at: Date
    var kind: LifeEventKind
    var note: String = ""
}

// MARK: - 每日记录

/// 一天一条。记漏服、睡眠、当天整体感受。用日期做键，两台设备同一天各记一条能合并。
struct DayLog: Codable, Identifiable, Hashable, SyncRecord {
    var id = UUID()
    var updatedAt: Date? = nil
    var date: DateOnly
    /// 今天没吃（主动停药或忘了），跟"还没吃"要区分开
    var skipped: Bool = false
    var skipReason: String = ""
    /// 昨晚几点睡的
    var sleepAt: Date? = nil
    /// 睡眠质量 1-5
    var sleepQuality: Int = 0
    /// 今天整体状态 1-5
    var overall: Int = 0
    var note: String = ""
}

// MARK: - 库存与处方

/// 库存与配药。规则里带主观成分的一律让用户自己填，App 不替他猜。
struct Supply: Codable, Hashable {
    var updatedAt: Date? = nil
    /// 现在还剩几粒
    var pillsLeft: Int = 0
    /// 一盒多少粒
    var perBox: Int = 30
    /// 上次配药日期
    var lastFill: DateOnly? = nil
    /// 处方还剩几次续配（repeat）
    var repeatsLeft: Int = 0
    /// 处方开具日期
    var scriptDate: DateOnly? = nil
    /// 两次配药之间药房执行的最短间隔（天）。默认 20，用户可按药房实际情况改。
    var minRefillGap: Int = 20
    /// 剩几粒时提醒该去配药
    var lowStockAlert: Int = 7

    /// 最早可以去配下一瓶的日期
    var earliestRefill: DateOnly? {
        guard let last = lastFill else { return nil }
        return last.adding(days: minRefillGap)
    }

    /// 距最早可配药还有几天（负数=已经可以配了）
    var daysToRefill: Int? {
        guard let e = earliestRefill else { return nil }
        return e.days(since: .today())
    }

    /// 处方失效日。NSW 的 S8 处方有效期 6 个月，从开具日起算，过期一律不能配。
    var scriptExpiry: DateOnly? { scriptDate?.adding(days: 183) }

    var daysToScriptExpiry: Int? {
        guard let e = scriptExpiry else { return nil }
        return e.days(since: .today())
    }

    /// 剩余续配全部配完最少需要多少天（每次之间要隔 minRefillGap）
    var daysNeededForRepeats: Int? {
        guard repeatsLeft > 0, let last = lastFill else { return nil }
        let finish = last.adding(days: minRefillGap * repeatsLeft)
        return finish.days(since: .today())
    }

    /// 按当前节奏，剩余续配能不能赶在处方过期前配完。
    /// 返回 nil 表示信息不全算不出。
    var repeatsFitBeforeExpiry: Bool? {
        guard repeatsLeft > 0, let expiry = scriptExpiry, let last = lastFill else { return nil }
        return last.adding(days: minRefillGap * repeatsLeft) <= expiry
    }
}
