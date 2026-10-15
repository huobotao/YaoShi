import Foundation
import Security
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// 同 Apple ID 的设备通过 iCloud 钥匙串交换各自的快照。
/// 每台设备只更新自己的条目，读取所有条目后按记录合并。
/// 钥匙串写入成功仅代表本机已提交，不能证明另一台设备已收到。

// MARK: - 业务键

extension Dose {
    /// 服药记录都是在某台设备上手动创建后持久化的，UUID 稳定，直接用
    var syncKey: String { "d:" + id.uuidString }
}

extension EffectLog {
    var syncKey: String { "e:" + id.uuidString }
}

extension LifeEvent {
    var syncKey: String { "l:" + id.uuidString }
}

extension DayLog {
    /// 一天只有一条日记录，用日期做键（两台设备同一天各记一条要能合并成一条）
    var syncKey: String { "y:" + date.iso }
}

// MARK: - 同步包

struct SyncPayload: Codable {
    var doses: [Dose] = []
    var effects: [EffectLog] = []
    var lifeEvents: [LifeEvent] = []
    var doseEpisode: DoseEpisodeSelection? = nil
    var days: [DayLog] = []
    var supply: Supply? = nil
    var settings: SyncedSettings? = nil
    /// 删除墓碑：业务键 -> 删除时刻
    var tombstones: [String: Date] = [:]
    var updatedAt: Date = Date()
    var deviceName: String = ""
    var acknowledged: [String: String]? = nil
    var inventory: InventorySyncState? = nil

    var isEmpty: Bool { doses.isEmpty && effects.isEmpty && lifeEvents.isEmpty && days.isEmpty && supply == nil && doseEpisode == nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case doses, effects, lifeEvents, days, supply, settings, tombstones
        case updatedAt, deviceName, acknowledged, inventory, doseEpisode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doses = try c.decode([Dose].self, forKey: .doses)
        effects = try c.decode([EffectLog].self, forKey: .effects)
        // 升级前的完整备份、手表导入日志和 iCloud 快照没有这个字段。
        lifeEvents = try c.decodeIfPresent([LifeEvent].self, forKey: .lifeEvents) ?? []
        doseEpisode = try c.decodeIfPresent(DoseEpisodeSelection.self, forKey: .doseEpisode)
        days = try c.decode([DayLog].self, forKey: .days)
        supply = try c.decodeIfPresent(Supply.self, forKey: .supply)
        settings = try c.decodeIfPresent(SyncedSettings.self, forKey: .settings)
        tombstones = try c.decode([String: Date].self, forKey: .tombstones)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        acknowledged = try c.decodeIfPresent([String: String].self, forKey: .acknowledged)
        inventory = try c.decodeIfPresent(InventorySyncState.self, forKey: .inventory)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(doses, forKey: .doses)
        try c.encode(effects, forKey: .effects)
        // 无新事件时保持旧版规范化内容不变，避免升级本身改变接收确认摘要。
        if !lifeEvents.isEmpty { try c.encode(lifeEvents, forKey: .lifeEvents) }
        try c.encodeIfPresent(doseEpisode, forKey: .doseEpisode)
        try c.encode(days, forKey: .days)
        try c.encodeIfPresent(supply, forKey: .supply)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encode(tombstones, forKey: .tombstones)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(acknowledged, forKey: .acknowledged)
        try c.encodeIfPresent(inventory, forKey: .inventory)
    }
}

/// 库存仍由用户确认实际数量；并发修改只标记冲突，不推算或猜测余量。
struct InventorySyncState: Codable, Hashable {
    var seenRevisions: [String] = []
    var conflictAt: Date? = nil
    var resolvedAt: Date? = nil
    var needsReview: Bool {
        guard let conflictAt else { return false }
        return resolvedAt == nil || conflictAt > resolvedAt!
    }
    static func revision(_ supply: Supply) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(supply)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    mutating func observe(_ supply: Supply) {
        seenRevisions = Array(Set(seenRevisions + [Self.revision(supply)])).sorted()
    }
    static func merge(local: SyncPayload, remote: SyncPayload) -> InventorySyncState {
        let a = local.inventory ?? InventorySyncState()
        let b = remote.inventory ?? InventorySyncState()
        var out = InventorySyncState()
        out.seenRevisions = Array(Set(a.seenRevisions + b.seenRevisions)).sorted()
        out.conflictAt = [a.conflictAt, b.conflictAt].compactMap { $0 }.max()
        out.resolvedAt = [a.resolvedAt, b.resolvedAt].compactMap { $0 }.max()
        if let left = local.supply, let right = remote.supply {
            let l = revision(left), r = revision(right)
            let independentRevisions = l != r && !a.seenRevisions.contains(r) && !b.seenRevisions.contains(l)
            let leftIDs = Set(local.doses.map(\.id)), rightIDs = Set(remote.doses.map(\.id))
            let independentDoses = !leftIDs.subtracting(rightIDs).isEmpty && !rightIDs.subtracting(leftIDs).isEmpty
            if independentRevisions || (independentDoses && l == r) {
                let editTime = [left.updatedAt, right.updatedAt,
                                local.doses.compactMap(\.updatedAt).max(), remote.doses.compactMap(\.updatedAt).max()]
                    .compactMap { $0 }.max() ?? Date(timeIntervalSince1970: 0)
                out.conflictAt = max(out.conflictAt ?? .distantPast, editTime)
            }
            out.observe(left); out.observe(right)
        } else if let supply = local.supply ?? remote.supply { out.observe(supply) }
        return out
    }
}

/// 需要跟着走的设置项（每台机器改了都同步，取 updatedAt 新的）
struct SyncedSettings: Codable, Hashable {
    var defaultMg: Int = 50
    /// nil 表示旧数据尚未设置，按 48 小时兼容；设置会随其他设置一并同步。
    var newRoundGapHoursOverride: Int? = nil
    /// 右苯丙胺血浆曲线参数，单位为 0.1 小时。nil 使用说明书参考值。
    var plasmaPeakTenthHoursOverride: Int? = nil
    var plasmaHalfLifeTenthHoursOverride: Int? = nil
    var targetHour: Int = 8          // 目标服药时刻（时）
    var targetMinute: Int = 0
    var lateCutoffHour: Int = 12     // 超过这个点再吃就会影响睡眠，发警告
    /// 希望几点睡。开着 autoCutoff 时，上面那个"别再吃了"的时刻由它倒推 14 小时算出。
    var bedtimeHour: Int = 23
    var bedtimeMinute: Int = 0
    var autoCutoff: Bool = true
    // 保留字段以兼容历史快照；当前 App 始终禁止安排提醒。
    var remindDaily: Bool = false
    var liveActivityEnabled: Bool = true
    var updatedAt: Date = .distantPast

    var newRoundGapHours: Int {
        get { min(max(newRoundGapHoursOverride ?? 48, 1), 720) }
        set { newRoundGapHoursOverride = min(max(newValue, 1), 720) }
    }

    var plasmaPeakTenthHours: Int {
        get { min(max(plasmaPeakTenthHoursOverride ?? 38, 10), 120) }
        set { plasmaPeakTenthHoursOverride = min(max(newValue, 10), 120) }
    }

    var plasmaHalfLifeTenthHours: Int {
        get { min(max(plasmaHalfLifeTenthHoursOverride ?? 107, 20), 300) }
        set { plasmaHalfLifeTenthHoursOverride = min(max(newValue, 20), 300) }
    }

    var plasmaCurve: PlasmaCurveConfiguration {
        PlasmaCurveConfiguration(peakTimeHours: Double(plasmaPeakTenthHours) / 10,
                                 halfLifeHours: Double(plasmaHalfLifeTenthHours) / 10)
    }
}

// MARK: - 合并

enum SyncMerge {

    // 设备可能长时间离线；没有所有设备的确认前不能按时间清掉删除标记。
    static func mergeTombstones(_ a: [String: Date], _ b: [String: Date]) -> [String: Date] {
        var out = a
        for (k, v) in b {
            if let old = out[k] { out[k] = max(old, v) } else { out[k] = v }
        }
        return out
    }

    /// 按业务键合并两组记录。同键取 updatedAt 较新者；被墓碑覆盖且未在删除后重新修改的丢弃。
    static func merge<T: SyncRecord & Encodable>(local: [T], remote: [T],
                                     tombstones: [String: Date],
                                     key: (T) -> String) -> [T] {
        var byKey: [String: T] = [:]
        for r in local + remote {
            let k = key(r)
            let stamp = r.updatedAt ?? .distantPast
            // 删除发生在这条记录最后一次修改之后 → 这条已经被删了
            if let dead = tombstones[k], stamp <= dead { continue }
            if let existing = byKey[k] {
                if stamp > (existing.updatedAt ?? .distantPast) ||
                    (stamp == (existing.updatedAt ?? .distantPast) && canonical(r) > canonical(existing)) {
                    byKey[k] = r
                }
            } else {
                byKey[k] = r
            }
        }
        return Array(byKey.values)
    }

    /// 把远端包并进本地包，返回合并结果
    static func merge(local: SyncPayload, remote: SyncPayload) -> SyncPayload {
        let tomb = mergeTombstones(local.tombstones, remote.tombstones)
        var out = SyncPayload()
        out.tombstones = tomb
        out.doses = merge(local: local.doses, remote: remote.doses,
                          tombstones: tomb) { $0.syncKey }
            .sorted { $0.at < $1.at }
        out.effects = merge(local: local.effects, remote: remote.effects,
                            tombstones: tomb) { $0.syncKey }
            .sorted { $0.at < $1.at }
        out.lifeEvents = merge(local: local.lifeEvents, remote: remote.lifeEvents,
                               tombstones: tomb) { $0.syncKey }
            .sorted { $0.at < $1.at }
        out.days = merge(local: local.days, remote: remote.days,
                         tombstones: tomb) { $0.syncKey }
            .sorted { $0.date < $1.date }
        // 库存和设置是单例，取修改时刻新的那份
        out.supply = newer(local.supply, remote.supply) { $0.updatedAt ?? .distantPast }
        out.inventory = InventorySyncState.merge(local: local, remote: remote)
        out.settings = newer(local.settings, remote.settings) { $0.updatedAt }
        out.doseEpisode = newer(local.doseEpisode, remote.doseEpisode) { $0.updatedAt }
        out.updatedAt = Date()
        out.deviceName = SyncStore.deviceName
        return out
    }

    private static func canonical<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? ""
    }

    private static func newer<T: Encodable>(_ a: T?, _ b: T?, stamp: (T) -> Date) -> T? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?):
            if stamp(x) == stamp(y) { return canonical(x) >= canonical(y) ? x : y }
            return stamp(x) > stamp(y) ? x : y
        }
    }
}

// MARK: - iCloud 钥匙串读写

protocol SyncKeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Any?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
}

struct SystemSyncKeychain: SyncKeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
}

struct SyncFailure: Error {
    let message: String
    let status: OSStatus?
}

struct SyncRead {
    var snapshots: [String: SyncPayload]
    var peers: [String: SyncPayload] {
        snapshots.filter { $0.key.hasPrefix("payload-v2-") && $0.key != SyncStore.account }
    }
}

enum SyncStore {
    private static let service = "com.richardhuo.yaoshi.archive.v21012r7.sync"
    private static let group = "P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012r7.shared"
    static let sizeLimit = 400_000

    // identifierForVendor 绑定本设备，恢复另一部手机的备份也不会共用写入槽。
    static var account: String {
        #if canImport(UIKit)
        if let id = UIDevice.current.identifierForVendor { return "payload-v2-" + id.uuidString }
        #endif
        let defaults = UserDefaults.standard
        let key = "syncDeviceID.v2"
        let id = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(id, forKey: key)
        return "payload-v2-" + id
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "测试设备"
        #endif
    }

    private static func query(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: true]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func canonicalData(_ payload: SyncPayload) -> Data? {
        var p = payload
        p.updatedAt = Date(timeIntervalSince1970: 0)
        p.deviceName = ""
        p.acknowledged = nil
        p.doses.sort { $0.syncKey < $1.syncKey }
        p.effects.sort { $0.syncKey < $1.syncKey }
        p.lifeEvents.sort { $0.syncKey < $1.syncKey }
        p.days.sort { $0.syncKey < $1.syncKey }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(p)
    }

    static func fingerprint(_ payload: SyncPayload) -> String {
        guard let data = canonicalData(payload) else { return "encoding-failed" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode(_ data: Data) -> SyncPayload? {
        let raw = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        return try? JSONDecoder().decode(SyncPayload.self, from: raw)
    }

    static func failure(_ status: OSStatus, action: String) -> SyncFailure {
        let explanation: String
        switch status {
        case errSecMissingEntitlement: explanation = "当前安装包缺少钥匙串共享权限，请更新 App"
        case errSecInteractionNotAllowed: explanation = "请解锁 iPhone 后再试"
        case errSecNotAvailable: explanation = "钥匙串暂不可用，请稍后重试"
        default: explanation = "系统钥匙串返回错误"
        }
        return SyncFailure(message: "\(action)失败：\(explanation)（\(status)）", status: status)
    }

    /// 读取所有设备的独立快照，同时保留对旧 payload-v1 的兼容。
    /// 只有 errSecItemNotFound 才表示本机钥匙串尚未出现数据，其他错误必须保留。
    static func pull(using keychain: any SyncKeychainAccess = SystemSyncKeychain()) -> Result<SyncRead, SyncFailure> {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, value) = keychain.read(q)
        if status == errSecItemNotFound { return .success(SyncRead(snapshots: [:])) }
        guard status == errSecSuccess else { return .failure(failure(status, action: "读取")) }
        guard let items = value as? [[String: Any]] else {
            return .failure(SyncFailure(message: "同步数据格式异常，已保留本机数据", status: nil))
        }
        var snapshots: [String: SyncPayload] = [:]
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String else { continue }
            guard name == "payload-v1" || name.hasPrefix("payload-v2-") else { continue }
            guard let data = item[kSecValueData as String] as? Data, let payload = decode(data) else {
                return .failure(SyncFailure(message: "发现无法读取的同步快照，暂停上传以保护数据", status: nil))
            }
            snapshots[name] = payload
        }
        return .success(SyncRead(snapshots: snapshots))
    }

    /// 只更新本设备条目；不删除旧条目，也不覆盖其他设备的并发改动。
    @discardableResult
    static func push(_ payload: SyncPayload, using keychain: any SyncKeychainAccess = SystemSyncKeychain(),
                     account localAccount: String? = nil) -> SyncResult {
        let ownAccount = localAccount ?? account
        var p = payload
        p.updatedAt = Date()
        p.deviceName = deviceName
        guard let raw = try? JSONEncoder().encode(p) else { return .failed(SyncFailure(message: "本地数据编码失败", status: nil)) }
        let compressed = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw
        guard compressed.count <= sizeLimit else {
            return .failed(SyncFailure(message: "数据超出同步容量，记录仍完整保存在本机", status: nil))
        }

        var readQuery = query(account: ownAccount)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let (readStatus, value) = keychain.read(readQuery)
        if readStatus == errSecSuccess {
            guard let data = value as? Data, let old = decode(data) else {
                return .failed(SyncFailure(message: "本机同步快照无法读取，未覆盖原数据", status: nil))
            }
            if canonicalData(old) == canonicalData(p), old.acknowledged == p.acknowledged { return .ok(bytes: data.count, changed: false) }
        } else if readStatus != errSecItemNotFound {
            return .failed(failure(readStatus, action: "读取"))
        }

        let attrs: [String: Any] = [kSecValueData as String: compressed,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = keychain.update(query(account: ownAccount), attributes: attrs)
        if status == errSecItemNotFound {
            var added = query(account: ownAccount)
            attrs.forEach { added[$0.key] = $0.value }
            status = keychain.add(added)
            if status == errSecDuplicateItem {
                status = keychain.update(query(account: ownAccount), attributes: attrs)
            }
        }
        guard status == errSecSuccess else { return .failed(failure(status, action: "写入")) }
        return .ok(bytes: compressed.count, changed: true)
    }
}

enum SyncResult {
    case ok(bytes: Int, changed: Bool)
    case failed(SyncFailure)

    var isOK: Bool { if case .ok = self { return true }; return false }
    var message: String {
        switch self {
        case .ok: return "本机已提交，等待 iCloud 传送"
        case .failed(let error): return error.message
        }
    }
    var error: SyncFailure? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
