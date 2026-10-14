import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import UIKit
#endif

/// One worker owns all ActivityKit mutations. While it awaits the system, only the
/// newest pending request is retained; an older update can never finish after a newer one.
@MainActor
final class DoseActivityWorkQueue<Input> {
    private var pending: Input?
    private var worker: Task<Void, Never>?
    private let perform: @MainActor (Input) async -> Void

    init(perform: @escaping @MainActor (Input) async -> Void) {
        self.perform = perform
    }

    @discardableResult
    func submit(_ input: Input) -> Task<Void, Never> {
        pending = input
        if let worker { return worker }
        let task = Task { @MainActor in
            while let input = self.pending {
                self.pending = nil
                await self.perform(input)
            }
            self.worker = nil
        }
        worker = task
        return task
    }
}

/// Replacement requires foreground eligibility. Updates never reset the system's eight-hour lifetime.
enum DoseActivityRenewalPolicy {
    static func shouldReplace(allowCreation: Bool, isForeground: Bool,
                              pushRequiresReplacement: Bool, startedAt: Date?, now: Date) -> Bool {
        guard allowCreation && isForeground else { return false }
        let age = startedAt.map { now.timeIntervalSince($0) }
        return pushRequiresReplacement || (age.map { $0 >= 7.5 * 3600 } ?? false)
    }
}

/// 常驻实时活动（锁屏 + 灵动岛）的启动、更新与收回。只在主 App 里编译。
///
/// 系统规则：一条实时活动最多活跃 8 小时，之后转入锁屏最多再留 4 小时，然后自动移除；
/// 只有 App 在前台时才能发起新的一条。所以策略是：每次进前台、每次数据变动都调 refresh，
/// 有活的就更新，没有就重新发起。
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
@available(iOS 16.2, *)
@MainActor
enum DoseActivityController {

    static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    private static var stateObservers: [String: Task<Void, Never>] = [:]

    private static func observe(_ activity: Activity<DoseAttributes>) {
        guard stateObservers[activity.id] == nil else { return }
        stateObservers[activity.id] = Task { @MainActor in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                report("stateChanged:" + String(describing: state))
                if state == .ended || state == .dismissed {
                    UserDefaults.standard.removeObject(forKey: "liveActivityStartedAt." + activity.id)
                    stateObservers.removeValue(forKey: activity.id)
                    return
                }
            }
            stateObservers.removeValue(forKey: activity.id)
        }
    }

    static var running: Activity<DoseAttributes>? {
        Activity<DoseAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    nonisolated static func state(from snap: SharedSnapshot, now: Date = Date(), calculatePeak: Bool = true) -> DoseAttributes.ContentState {
        let doses: [Dose]
        if let ticks = snap.recentDoses {
            doses = ticks.map(\.asDose)
        } else if let last = snap.status.lastDoseAt {
            doses = [Dose(at: last, mg: snap.status.lastMg)]
        } else {
            doses = []
        }
        let actual = doses.filter { $0.at <= now && $0.at.timeIntervalSinceReferenceDate.isFinite && $0.mg > 0 }
        // Compute only displayed fields; DoseStatus.compute also performs a 48-hour
        // threshold search unused by Live Activities, expensive for a future schedule.
        let last = actual.max { $0.at < $1.at }
        let hours = last.map { now.timeIntervalSince($0.at) / 3600 } ?? 0
        let status = DoseStatus(lastDoseAt: last?.at, lastMg: last?.mg ?? 0,
            phase: last == nil ? .none : DoseEngine.phase(hoursSinceDose: hours),
            level: last.map { DoseEngine.level(hoursSinceDose: hours, food: $0.food) } ?? 0,
            remaining: last == nil ? 0 : DoseEngine.remaining(hoursSinceDose: hours),
            peakEndAt: last.map { DoseEngine.peakEndTime(of: $0) },
            effectEndAt: last.map { DoseEngine.endTime(of: $0) },
            takenToday: actual.filter { $0.dateOnly == DateOnly(now) }.count, generatedAt: now)
        return DoseAttributes.ContentState(
            lastDoseAt: status.lastDoseAt,
            lastMg: status.lastMg,
            phaseRaw: status.phase.rawValue,
            level: status.level,
            remainingRaw: status.remaining,
            plasmaSlopePerHour: actual.isEmpty ? nil : PlasmaTrend.slope(doses: actual, at: now, curve: snap.plasmaCurve),
            peakEndAt: status.peakEndAt,
            effectEndAt: status.effectEndAt,
            takenToday: status.takenToday,
            targetAt: snap.targetAt,
            skippedToday: snap.skippedToday && Calendar.current.isDate(snap.updatedAt, inSameDayAs: now),
            pillsLeft: snap.pillsLeft,
            concentrationRatio: actual.isEmpty ? nil : DoseEngine.totalPlasma(actual, at: now, curve: snap.plasmaCurve),
            predictedPeakAt: calculatePeak ? DoseEngine.nextLocalPlasmaPeak(doses: actual, now: now, curve: snap.plasmaCurve) : nil,
            episodeStartedAt: snap.episodeStartedAt.flatMap {
                $0.timeIntervalSinceReferenceDate.isFinite && $0 <= now ? $0 : nil
            },
            curve: DoseActivityCurve.make(doses: actual, now: now, curve: snap.plasmaCurve),
            refreshedAt: now)
    }

    /// Trend expires after 60 seconds or at an earlier phase boundary; expiry is not an update.
    nonisolated static func nextStale(for st: DoseAttributes.ContentState, now: Date, maximumAge: TimeInterval = 60) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let candidates: [Date?] = [now.addingTimeInterval(maximumAge), tomorrow.addingTimeInterval(300),
                                   st.predictedPeakAt, st.peakEndAt, st.effectEndAt, st.targetAt]
        return candidates.compactMap { $0 }.filter { $0 > now }.min() ?? tomorrow
    }

    private enum Request {
        case refresh(SharedSnapshot, allowCreation: Bool)
        case end
    }

    private static let work = DoseActivityWorkQueue<Request> { request in
        await apply(request)
    }

    static func refresh(from snap: SharedSnapshot, settings: SyncedSettings) {
        // Disabling must withdraw existing cards even if authorization was revoked.
        guard settings.liveActivityEnabled else { endAll(); return }
        work.submit(.refresh(snap, allowCreation: UIApplication.shared.applicationState == .active))
    }

    /// A background intent may refresh an existing activity, but must never create one.
    /// Awaiting the worker keeps the intent alive until the accepted work has completed.
    static func refreshExisting(from snap: SharedSnapshot, settings: SyncedSettings) async {
        let request: Request = settings.liveActivityEnabled ? .refresh(snap, allowCreation: false) : .end
        await work.submit(request).value
    }

    private static func apply(_ request: Request) async {
        switch request {
        case .end:
            for activity in Activity<DoseAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
                LiveActivityPush.withdraw(activity.id)
            }
            report("ended")
        case let .refresh(snap, allowCreation):
            guard isSupported else { report("notAuthorized"); return }
            var retained = running
            var replacing: Activity<DoseAttributes>?
            if let old = retained {
                observe(old)
                let key = "liveActivityStartedAt." + old.id
                let stored = UserDefaults.standard.object(forKey: key) as? Double
                let pushNeedsReplacement = LiveActivityPush.requiresReplacement(old, snapshot: snap) ||
                    (LiveActivityPush.configured && old.pushToken == nil &&
                     !(UserDefaults.standard.stringArray(forKey: "pushRequestedActivityIDs") ?? []).contains(old.id))
                if DoseActivityRenewalPolicy.shouldReplace(allowCreation: allowCreation,
                        isForeground: UIApplication.shared.applicationState == .active,
                        pushRequiresReplacement: pushNeedsReplacement,
                        startedAt: stored.map(Date.init(timeIntervalSince1970:)), now: Date()) {
                    // Keep the old card until a replacement was actually accepted.
                    replacing = old
                    retained = nil
                }
            }
            // Await removal before either updating or requesting, so repeated refreshes
            // cannot race with cleanup or create multiple lock-screen cards.
            for activity in Activity<DoseAttributes>.activities where activity.id != retained?.id && activity.id != replacing?.id {
                await activity.end(nil, dismissalPolicy: .immediate)
                LiveActivityPush.withdraw(activity.id)
            }
            let now = Date()
            let st = state(from: snap, now: now)
            let content = ActivityContent(state: st, staleDate: nextStale(for: st, now: now, maximumAge: LiveActivityPush.configured ? 120 : 60))
            if let activity = retained,
               activity.activityState == .active || activity.activityState == .stale {
                await activity.update(content)
                LiveActivityPush.maintain(activity, snapshot: snap)
                report("updated")
            } else {
                guard allowCreation, UIApplication.shared.applicationState == .active else {
                    report("creationDeferredUntilForeground")
                    return
                }
                do {
                    let activity = try Activity.request(attributes: DoseAttributes(title: "药时"),
                                             content: content, pushType: LiveActivityPush.configured ? .token : nil)
                    observe(activity)
                    UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "liveActivityStartedAt." + activity.id)
                    if let old = replacing {
                        await old.end(nil, dismissalPolicy: .immediate)
                        LiveActivityPush.withdraw(old.id)
                        UserDefaults.standard.removeObject(forKey: "liveActivityStartedAt." + old.id)
                    }
                    if LiveActivityPush.configured {
                        var ids = UserDefaults.standard.stringArray(forKey: "pushRequestedActivityIDs") ?? []
                        ids.append(activity.id)
                        UserDefaults.standard.set(Array(ids.suffix(20)), forKey: "pushRequestedActivityIDs")
                    }
                    LiveActivityPush.maintain(activity, snapshot: snap)
                    report("started")
                } catch {
                    // Failed renewal must not remove the working card.
                    if let old = replacing { await old.update(content) }
                    report("requestFailed", error: String(describing: error))
                }
            }
        }
    }

    /// Local diagnostics distinguish an installed build from an accepted ActivityKit update.
    private static func report(_ action: String, error: String? = nil) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var report: [String: Any] = [
            "action": action, "checkedAt": Date().timeIntervalSince1970,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "activitiesEnabled": isSupported,
            "activities": Activity<DoseAttributes>.activities.map { activity -> [String: Any] in
                let state = activity.content.state
                var item: [String: Any] = ["id": activity.id,
                    "state": String(describing: activity.activityState),
                    "refreshedAt": state.refreshedAt.timeIntervalSince1970]
                if let stale = activity.content.staleDate { item["staleDateUnix"] = stale.timeIntervalSince1970 }
                if let started = UserDefaults.standard.object(forKey: "liveActivityStartedAt." + activity.id) as? Double {
                    item["startedAtUnix"] = started
                }
                if let slope = state.plasmaSlopePerHour {
                    item["plasmaSlopePerHour"] = slope
                    item["trendAngleDegrees"] = PlasmaTrend.angleDegrees(slope: slope)
                }
                if let value = state.concentrationRatio { item["concentrationRatio"] = value }
                if let peak = state.predictedPeakAt { item["predictedPeakAt"] = peak.timeIntervalSince1970 }
                return item
            }
        ]
        if let error { report["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("live-activity-status.json"), options: .atomic)
        }
    }

    static func endAll() {
        work.submit(.end)
    }
}
#else
/// Live Activities are an iPhone system feature; recording remains available on Mac.
enum DoseActivityController {
    static var isSupported: Bool { false }
    static func refresh(from snap: SharedSnapshot, settings: SyncedSettings) {}
    static func endAll() {}
    static func refreshExisting(from snap: SharedSnapshot, settings: SyncedSettings) async {}
}
#endif
