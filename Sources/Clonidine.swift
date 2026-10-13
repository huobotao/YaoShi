import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// 可乐定属于独立记录，不进入 Vyvanse 的 Dose、浓度曲线、用药状态或统计。
struct ClonidineEntry: Codable, Identifiable, Hashable, SyncRecord {
    var id = UUID()
    var updatedAt: Date? = nil
    var at: Date
    var mg: Decimal
    var note: String = ""

    var doseText: String { NSDecimalNumber(decimal: mg).stringValue }
    var syncKey: String { "c:" + id.uuidString }
}

/// 独立的本机与 iCloud 钥匙串快照。旧版药时只读主药服务，不会解码或改写此数据。
struct ClonidineSnapshot: Codable, Hashable {
    var entries: [ClonidineEntry] = []
    var tombstones: [String: Date] = [:]
    var updatedAt: Date = Date()
    var deviceName: String = ""

    static func merge(_ lhs: ClonidineSnapshot, _ rhs: ClonidineSnapshot) -> ClonidineSnapshot {
        var tombstones = lhs.tombstones
        for (key, date) in rhs.tombstones {
            tombstones[key] = max(tombstones[key] ?? .distantPast, date)
        }

        var byID: [UUID: ClonidineEntry] = [:]
        for entry in lhs.entries + rhs.entries {
            if let deleted = tombstones[entry.syncKey], (entry.updatedAt ?? .distantPast) <= deleted { continue }
            if let old = byID[entry.id] {
                let newStamp = entry.updatedAt ?? .distantPast
                let oldStamp = old.updatedAt ?? .distantPast
                if newStamp > oldStamp || (newStamp == oldStamp && canonical(entry) > canonical(old)) {
                    byID[entry.id] = entry
                }
            } else {
                byID[entry.id] = entry
            }
        }
        return ClonidineSnapshot(entries: byID.values.sorted { $0.at < $1.at },
                                 tombstones: tombstones, updatedAt: Date(),
                                 deviceName: ClonidineSyncStore.deviceName)
    }

    private static func canonical(_ entry: ClonidineEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(entry)) ?? Data(), encoding: .utf8) ?? ""
    }

    static func fingerprint(_ snapshot: ClonidineSnapshot) -> String {
        var stable = snapshot
        stable.updatedAt = Date(timeIntervalSince1970: 0)
        stable.deviceName = ""
        stable.entries.sort { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(stable)) ?? Data(), encoding: .utf8) ?? ""
    }
}

enum ClonidineSyncStore {
    private static let service = "com.richardhuio.yaoshi.clonidine.sync"
    private static let group = "P272ZF8FA9.com.richardhuo.yaoshi.shared"
    private static let accountPrefix = "clonidine-v1-"

    static var account: String {
        #if canImport(UIKit)
        if let id = UIDevice.current.identifierForVendor { return accountPrefix + id.uuidString }
        #endif
        let defaults = UserDefaults.standard
        let key = "clonidineSyncDeviceID.v1"
        let id = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(id, forKey: key)
        return accountPrefix + id
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

    static func pull(using keychain: any SyncKeychainAccess = SystemSyncKeychain()) -> Result<[String: ClonidineSnapshot], SyncFailure> {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, value) = keychain.read(q)
        if status == errSecItemNotFound { return .success([:]) }
        guard status == errSecSuccess else {
            return .failure(SyncStore.failure(status, action: "读取可乐定同步"))
        }
        guard let items = value as? [[String: Any]] else {
            return .failure(SyncFailure(message: "可乐定同步数据格式异常，已保留本机记录", status: nil))
        }
        var snapshots: [String: ClonidineSnapshot] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix) else { continue }
            guard let data = item[kSecValueData as String] as? Data,
                  let snapshot = try? JSONDecoder().decode(ClonidineSnapshot.self, from: data) else {
                return .failure(SyncFailure(message: "可乐定同步数据无法读取，已保留原记录", status: nil))
            }
            snapshots[account] = snapshot
        }
        return .success(snapshots)
    }

    static func push(_ snapshot: ClonidineSnapshot,
                     using keychain: any SyncKeychainAccess = SystemSyncKeychain()) -> Result<Void, SyncFailure> {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return .failure(SyncFailure(message: "可乐定记录编码失败", status: nil))
        }
        guard data.count <= 200_000 else {
            return .failure(SyncFailure(message: "可乐定同步数据超出容量；原记录仍保存在本机", status: nil))
        }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = keychain.update(query(account: account), attributes: attrs)
        if status == errSecItemNotFound {
            var add = query(account: account)
            attrs.forEach { add[$0.key] = $0.value }
            status = keychain.add(add)
            if status == errSecDuplicateItem {
                status = keychain.update(query(account: account), attributes: attrs)
            }
        }
        guard status == errSecSuccess else {
            return .failure(SyncStore.failure(status, action: "写入可乐定同步"))
        }
        return .success(())
    }
}
