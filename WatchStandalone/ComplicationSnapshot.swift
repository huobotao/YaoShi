import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A validated, read-only copy for the separate WidgetKit process.
/// The widget never opens the app's private Documents directory.
enum ComplicationSnapshot {
    static let groupID = "group.com.richardhuo.yaoshi.watch.healthr4"
    static let widgetKind = "YaoShiWatchCurveR4"
    private static let filename = "complication-import-v1.json"
    private static let journalFilename = "complication-dose-journal-v1.json"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(filename)
    }
    private static var journalURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(journalFilename)
    }

    static func read(now: Date = Date()) -> StandaloneImport? {
        guard let url,
              let bytes = try? Data(contentsOf: url), bytes.count <= 2_000_000 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? decoder.decode(StandaloneImport.self, from: bytes),
              (try? data.validate(now: now)) != nil else { return nil }
        guard let journalURL else { return nil }
        if !FileManager.default.fileExists(atPath: journalURL.path) { return data }
        // A corrupt local journal must not silently turn a pending Watch dose
        // into an apparently current widget estimate.
        guard let journal = try? DoseJournal(url: journalURL) else { return nil }
        return StandaloneImport(schema: data.schema,
                                sourceCapturedAt: data.sourceCapturedAt,
                                exportedAt: data.exportedAt,
                                sourceSHA256: data.sourceSHA256,
                                peakHours: data.peakHours,
                                halfLifeHours: data.halfLifeHours,
                                doses: journal.mergedDoses(imported: data.doses))
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

    /// Mirror only the independently validated Watch journal to the widget.
    /// The iPhone import and its source hash remain untouched.
    @discardableResult
    static func publishLocal(_ journal: DoseJournal) -> Bool {
        guard let journalURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(DoseJournalFile(schema: 1, events: journal.events)),
              bytes.count <= 4_000_000 else { return false }
        do {
            try bytes.write(to: journalURL, options: .atomic)
            _ = try DoseJournal(url: journalURL)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            #endif
            return true
        } catch { return false }
    }
}
