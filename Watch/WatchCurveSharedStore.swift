import Foundation

/// Only the R7 watch app and its complication extension share this container.
/// The phone-to-watch transport and the watch's pending-record journal remain private.
enum WatchCurveSharedStore {
    static let group = "group.com.richardhuo.yaoshi.archive.v21012r7.watch"
    static let complicationKind = "YaoShiR7WatchCurve"
    private static let filename = "curve-snapshot-v1.json"

    struct Snapshot: Codable {
        let generatedAt: Date
        let curve: WatchCurveSnapshot
    }

    static func read() -> Snapshot? {
        guard let url = fileURL(), let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: bytes)
    }

    @discardableResult
    static func write(_ snapshot: WatchPhoneSnapshot?) -> Bool {
        guard let url = fileURL() else { return false }
        guard let snapshot, let curve = snapshot.curve else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        do {
            let bytes = try JSONEncoder().encode(Snapshot(generatedAt: snapshot.generatedAt, curve: curve))
            try bytes.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    private static func fileURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(filename)
    }
}
