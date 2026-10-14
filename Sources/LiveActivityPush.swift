import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import UIKit

/// Only installed locally by the owner. Never bundled or synchronized with medication data.
struct LiveActivityPushConfiguration: Codable {
    let endpoint: URL
    let authorizationToken: String
    let environment: String

    static func load() -> Self? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: documents.appendingPathComponent("live-activity-push-config.json")),
              let config = try? JSONDecoder().decode(Self.self, from: data),
              config.isUsable(provisionedEnvironment: provisionedEnvironment()) else { return nil }
        return config
    }

    func isUsable(provisionedEnvironment: String?) -> Bool {
        endpoint.scheme == "https" && endpoint.host != nil && endpoint.user == nil && endpoint.password == nil &&
        !authorizationToken.isEmpty && ["sandbox", "production"].contains(environment) &&
        provisionedEnvironment == (environment == "sandbox" ? "development" : "production")
    }

    private static func provisionedEnvironment() -> String? {
        guard let path = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bytes = try? Data(contentsOf: path),
              let start = bytes.range(of: Data("<?xml".utf8)),
              let end = bytes.range(of: Data("</plist>".utf8), in: start.lowerBound..<bytes.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: bytes[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}

/// A duplicate foreground notification must not restart an in-flight bounded retry.
struct LiveActivityRegistrationGate {
    private struct Job {
        let id: UUID
        let fingerprint: Data
        let token: Data
    }
    private var jobs: [String: Job] = [:]

    mutating func begin(activity: String, fingerprint: Data, token: Data) -> UUID? {
        if let job = jobs[activity], job.fingerprint == fingerprint, job.token == token { return nil }
        let id = UUID()
        jobs[activity] = Job(id: id, fingerprint: fingerprint, token: token)
        return id
    }

    func jobID(for activity: String) -> UUID? { jobs[activity]?.id }

    @discardableResult
    mutating func finish(activity: String, jobID: UUID) -> Bool {
        guard jobs[activity]?.id == jobID else { return false }
        jobs.removeValue(forKey: activity)
        return true
    }

    mutating func cancel(activity: String) { jobs.removeValue(forKey: activity) }
}

@available(iOS 16.2, *)
@MainActor
enum LiveActivityPush {
    struct Entry: Codable {
        let at: Int
        let staleAt: Int
        let contentState: DoseAttributes.ContentState
    }
    struct Registration: Codable {
        let generation: Int64
        let token: String
        let topic: String
        let environment: String
        let expiresAt: Int
        let schedule: [Entry]
    }
    private struct Fingerprint: Encodable {
        let doses: [DoseTick]?
        let legacyLast: Date?
        let legacyMg: Int?
        let peak: Int?
        let halfLife: Int?
        let target: Date?
        let skipped: Bool
        let pills: Int
        let episodeStartedAt: Date?
    }
    private static var observers: [String: Task<Void, Never>] = [:]
    private static var latestSnapshot: SharedSnapshot?
    private static var completedFingerprint: [String: Data] = [:]
    private static var completedToken: [String: Data] = [:]
    private static var expires: [String: Date] = [:]
    private static var registrationGate = LiveActivityRegistrationGate()
    private static var withdrawals: [String: Task<Void, Never>] = [:]
    private static var pending: [String: Task<Void, Never>] = [:]
    static func requiresReplacement(_ activity: Activity<DoseAttributes>, snapshot: SharedSnapshot) -> Bool {
        guard activity.pushToken != nil || (UserDefaults.standard.stringArray(forKey: "pushRequestedActivityIDs") ?? []).contains(activity.id),
              let old = UserDefaults.standard.string(forKey: "pushSnapshot." + activity.id) else { return false }
        return old != fingerprint(snapshot).base64EncodedString()
    }

    static var configured: Bool { LiveActivityPushConfiguration.load() != nil }

    static func maintain(_ activity: Activity<DoseAttributes>, snapshot: SharedSnapshot) {
        latestSnapshot = snapshot
        guard configured else { report("notConfigured"); return }
        UserDefaults.standard.set(fingerprint(snapshot).base64EncodedString(), forKey: "pushSnapshot." + activity.id)
        if observers[activity.id] == nil {
            observers[activity.id] = Task {
                for await token in activity.pushTokenUpdates {
                    guard !Task.isCancelled, let snap = latestSnapshot else { return }
                    enqueue(activity, token: token, snapshot: snap)
                }
            }
        }
        if let token = activity.pushToken { enqueue(activity, token: token, snapshot: snapshot) }
        else { report("waitingForActivityPushToken") }
    }

    static func fingerprint(_ snap: SharedSnapshot) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Fingerprint(doses: snap.recentDoses,
            legacyLast: snap.recentDoses == nil ? snap.status.lastDoseAt : nil,
            legacyMg: snap.recentDoses == nil ? snap.status.lastMg : nil,
            peak: snap.plasmaPeakTenthHoursOverride, halfLife: snap.plasmaHalfLifeTenthHoursOverride,
            target: snap.targetAt, skipped: snap.skippedToday, pills: snap.pillsLeft,
            episodeStartedAt: snap.episodeStartedAt))) ?? Data()
    }

    private static func nextGeneration() -> Int64 {
        let key = "liveActivityPushGeneration"
        let old = Int64(UserDefaults.standard.double(forKey: key))
        let value = max(old + 1, Int64(Date().timeIntervalSince1970 * 1000))
        UserDefaults.standard.set(Double(value), forKey: key)
        return value
    }

    nonisolated static func buildSchedule(snapshot: SharedSnapshot, started: Date) -> [Entry] {
                var result: [Entry] = []
                var nextPeak: Date?
                for index in 0..<960 {
                    let at = Date(timeIntervalSince1970: floor(started.timeIntervalSince1970) + Double(index * 30))
                    var state = DoseActivityController.state(from: snapshot, now: at, calculatePeak: false)
                    if index == 0 || (nextPeak != nil && nextPeak! <= at) {
                        nextPeak = DoseActivityController.state(from: snapshot, now: at).predictedPeakAt
                    }
                    state.predictedPeakAt = nextPeak
                    result.append(Entry(at: Int(at.timeIntervalSince1970), staleAt: Int(DoseActivityController.nextStale(for: state, now: at, maximumAge: 120).timeIntervalSince1970.rounded(.up)), contentState: state))
                }
                return result
    }

    private static func enqueue(_ activity: Activity<DoseAttributes>, token: Data, snapshot: SharedSnapshot) {
        let id = activity.id
        let signature = fingerprint(snapshot)
        guard completedFingerprint[id] != signature || completedToken[id] != token ||
              (expires[id] ?? .distantPast).timeIntervalSinceNow < 3600 else { return }
        // Preserve an identical in-flight upload, including its existing retry budget.
        guard let jobID = registrationGate.begin(activity: id, fingerprint: signature, token: token) else { return }
        // A genuinely changed token/model supersedes the older job.
        pending[id]?.cancel()
        let generation = nextGeneration()
        pending[id] = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "Register Live Activity schedule") {
                Task { @MainActor in
                    if registrationGate.jobID(for: id) == jobID { pending[id]?.cancel() }
                }
            }
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                if registrationGate.finish(activity: id, jobID: jobID) { pending[id] = nil }
            }
            guard let config = LiveActivityPushConfiguration.load() else { return }
            let started = Date()
            let entries = await Task.detached(priority: .utility) { () -> [Entry] in
                buildSchedule(snapshot: snapshot, started: started)
            }.value
            guard !Task.isCancelled else { return }
            let expiration = started.addingTimeInterval(8 * 3600)
            let body = Registration(generation: generation, token: token.map { String(format: "%02x", $0) }.joined(),
                topic: (Bundle.main.bundleIdentifier ?? "") + ".push-type.liveactivity", environment: config.environment,
                expiresAt: Int(expiration.timeIntervalSince1970), schedule: entries)
            do {
                let encoded = try JSONEncoder().encode(body)
                try await registerWithRetry(id: id, body: encoded, config: config)
                guard !Task.isCancelled else { return }
                completedFingerprint[id] = signature; completedToken[id] = token; expires[id] = expiration
                report("scheduleAccepted", generation: generation)
            } catch {
                if !Task.isCancelled { report("registrationFailed", error: String(describing: error)) }
            }
        }
    }

    /// Cancel local work synchronously. The independent DELETE cannot delay creating
    /// a replacement activity, and its generation supersedes any cancelled PUT.
    static func withdraw(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "pushSnapshot." + id)
        observers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.cancel()
        registrationGate.cancel(activity: id)
        completedFingerprint.removeValue(forKey: id); completedToken.removeValue(forKey: id); expires.removeValue(forKey: id)
        guard withdrawals[id] == nil, let config = LiveActivityPushConfiguration.load() else { return }
        let generation = nextGeneration()
        withdrawals[id] = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "Withdraw Live Activity schedule") {
                Task { @MainActor in withdrawals[id]?.cancel() }
            }
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                withdrawals[id] = nil
            }
            do {
                try Task.checkCancellation()
                let body = try JSONEncoder().encode(["generation": generation])
                try await send(id: id, method: "DELETE", body: body, config: config)
                report("withdrawn")
            } catch {
                if !Task.isCancelled { report("withdrawFailed", error: String(describing: error)) }
            }
        }
    }

    private static func registerWithRetry(id: String, body: Data, config: LiveActivityPushConfiguration) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                try await send(id: id, method: "PUT", body: body, config: config)
                return
            } catch {
                let ns = error as NSError
                let retryable = ns.domain == NSURLErrorDomain || (ns.domain == "LiveActivityPush" && (ns.code == 429 || ns.code >= 500))
                guard retryable, attempt < 2, !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 2 : 5) * 1_000_000_000)
            }
        }
    }

    private static func send(id: String, method: String, body: Data, config: LiveActivityPushConfiguration) async throws {
        let url = config.endpoint.appendingPathComponent("v1").appendingPathComponent("activities").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("Bearer " + config.authorizationToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "LiveActivityPush", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Relay did not accept the update"])
        }
    }

    private static func report(_ action: String, generation: Int64? = nil, error: String? = nil) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var item: [String: Any] = ["action": action, "checkedAt": Date().timeIntervalSince1970]
        if let generation { item["generation"] = generation }
        if let error { item["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: item, options: .sortedKeys) {
            try? data.write(to: directory.appendingPathComponent("live-activity-push-status.json"), options: .atomic)
        }
    }
}
#endif
