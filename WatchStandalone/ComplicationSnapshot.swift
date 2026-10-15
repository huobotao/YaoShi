import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A validated, read-only copy for the separate WidgetKit process.
/// The widget never opens the app's private Documents directory.
enum ComplicationSnapshot {
    static let groupID = "group.com.richardhuo.yaoshi.watch.healthr2"
    static let widgetKind = "YaoShiWatchCurveR2"
    private static let filename = "complication-import-v1.json"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(filename)
    }

    static func read(now: Date = Date()) -> StandaloneImport? {
        guard let url,
              let bytes = try? Data(contentsOf: url), bytes.count <= 2_000_000 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? decoder.decode(StandaloneImport.self, from: bytes),
              (try? data.validate(now: now)) != nil else { return nil }
        return data
    }

    @discardableResult
    static func publish(_ data: StandaloneImport) -> Bool {
        guard (try? data.validate()) != nil, let url else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let bytes = try? encoder.encode(data), bytes.count <= 2_000_000 else { return false }
        do {
            try bytes.write(to: url, options: .atomic)
            guard read()?.sourceSHA256 == data.sourceSHA256 else { return false }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            #endif
            return true
        } catch { return false }
    }
}
