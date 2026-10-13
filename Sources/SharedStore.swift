import Foundation
import Security

/// 小组件要自己算叠加曲线，就得知道最近这几片药分别是什么时候吃的。
/// 只带必要的三个字段，整个数组很小。
struct DoseTick: Codable, Hashable {
    var at: Date
    var mg: Int
    var food: FoodState

    /// 还原成能喂给 DoseEngine 的 Dose
    var asDose: Dose { Dose(at: at, mg: mg, food: food) }
}

/// 主 App、小组件、灵动岛共用的一份快照。
///
/// 通配描述文件没有 App Group 权限，只有 keychain-access-groups，
/// 所以走钥匙串共享——数据量很小，完全够用；同时在沙盒里留一份文件兜底。
struct SharedSnapshot: Codable {
    var status: DoseStatus
    /// 旧版本目标服药时刻；保留字段兼容历史快照，按需记录不再使用。
    var targetAt: Date?
    /// 还剩几粒
    var pillsLeft: Int = 0
    /// 距最早可配药还有几天（负数=已经可以配）
    var daysToRefill: Int? = nil
    /// 今天是否被标记为不吃
    var skippedToday: Bool = false
    /// 已发生的服药，供小组件在任意时刻计算自然衰减。保留字段名兼容旧快照。
    /// 旧版快照没有这个字段，解码为 nil，此时退回只看最后一次。
    var recentDoses: [DoseTick]? = nil
    /// 小组件使用与主 App 相同的自定义曲线参数；旧快照按说明书默认值计算。
    var plasmaPeakTenthHoursOverride: Int? = nil
    var plasmaHalfLifeTenthHoursOverride: Int? = nil
    var updatedAt: Date = Date()

    /// 还原成 Dose 数组
    var doses: [Dose] { (recentDoses ?? []).map(\.asDose) }

    var plasmaCurve: PlasmaCurveConfiguration {
        PlasmaCurveConfiguration(
            peakTimeHours: Double(min(max(plasmaPeakTenthHoursOverride ?? 38, 10), 120)) / 10,
            halfLifeHours: Double(min(max(plasmaHalfLifeTenthHoursOverride ?? 107, 20), 300)) / 10)
    }

    static var empty: SharedSnapshot {
        SharedSnapshot(status: DoseStatus(lastDoseAt: nil, lastMg: 0, phase: .none, level: 0,
                                          peakEndAt: nil, effectEndAt: nil,
                                          takenToday: 0, generatedAt: Date()),
                       targetAt: nil)
    }

    /// 按需服用没有「逾期未服药」状态；保留接口兼容旧调用方。
    var overdue: Bool { false }
}

enum SharedStore {
    private static let service = "com.richardhuo.yaoshi.snapshot"
    private static let account = "current"
    private static let group = "P272ZF8FA9.com.richardhuo.yaoshi.shared"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
    }

    static func save(_ snap: SharedSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        var q = baseQuery()
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
        // 钥匙串组不可用时退回沙盒文件，至少主 App 自己能读
        if let url = fallbackURL { try? data.write(to: url, options: .atomic) }
    }

    static func load() -> SharedSnapshot? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = try? JSONDecoder().decode(SharedSnapshot.self, from: d) {
            return s
        }
        if let url = fallbackURL, let d = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(SharedSnapshot.self, from: d)
        }
        return nil
    }

    private static var fallbackURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("snapshot.json")
    }
}
