import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Explicit development launch mode. It never loads Store, sync, or mutation APIs.
/// The fixed private output is intentionally separate from normal publish diagnostics.
enum LiveActivityReadback {
    static var requested: Bool {
        ProcessInfo.processInfo.environment["YAOSHI_ACTIVITY_READBACK"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--yaoshi-activity-readback")
    }

    static var nonce: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--yaoshi-activity-readback"),
              arguments.indices.contains(index + 1) else { return "" }
        return String(arguments[index + 1].prefix(128))
    }

    @MainActor
    static func capture() {
        let now = Date()
        var report: [String: Any] = [
            "mode": "read-only-no-store", "nonce": nonce,
            "capturedAtUnix": now.timeIntervalSince1970,
            "contentStateDateEncoding": "seconds-since-2001-01-01",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        ]
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.2, *) {
            report["supported"] = true
            report["activities"] = Activity<DoseAttributes>.activities.map { activity -> [String: Any] in
                let content = activity.content
                var item: [String: Any] = [
                    "id": activity.id,
                    "activityState": String(describing: activity.activityState),
                    "relevanceScore": content.relevanceScore,
                ]
                if let stale = content.staleDate { item["staleDateUnix"] = stale.timeIntervalSince1970 }
                // Default Date encoding matches ActivityKit ContentState push payloads.
                do {
                    let data = try JSONEncoder().encode(content.state)
                    item["contentState"] = try JSONSerialization.jsonObject(with: data)
                } catch {
                    item["contentEncodingFailed"] = true
                }
                return item
            }
        } else {
            report["supported"] = false
            report["activities"] = []
        }
        #else
        report["supported"] = false
        report["activities"] = []
        #endif
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("live-activity-readback.json")
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            // No values, identifiers, tokens, or record contents in process logs.
            print("Live Activity read-only capture saved")
        } catch {
            print("Live Activity read-only capture failed")
        }
    }
}
