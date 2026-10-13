import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// 常驻实时活动（锁屏 + 灵动岛）的启动、更新与收回。只在主 App 里编译。
///
/// 系统规则：一条实时活动最多活跃 8 小时，之后转入锁屏最多再留 4 小时，然后自动移除；
/// 只有 App 在前台时才能发起新的一条。所以策略是：每次进前台、每次数据变动都调 refresh，
/// 有活的就更新，没有就重新发起。
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
@available(iOS 16.2, *)
enum DoseActivityController {

    static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static var running: Activity<DoseAttributes>? {
        Activity<DoseAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    static func state(from snap: SharedSnapshot, now: Date = Date()) -> DoseAttributes.ContentState {
        let doses: [Dose]
        if let ticks = snap.recentDoses {
            doses = ticks.map(\.asDose)
        } else if let last = snap.status.lastDoseAt {
            doses = [Dose(at: last, mg: snap.status.lastMg)]
        } else {
            doses = []
        }
        let actual = doses.filter { $0.at <= now && $0.at.timeIntervalSinceReferenceDate.isFinite && $0.mg > 0 }
        return DoseAttributes.ContentState(
            lastDoseAt: snap.status.lastDoseAt,
            lastMg: snap.status.lastMg,
            phaseRaw: snap.status.phase.rawValue,
            level: snap.status.level,
            remainingRaw: snap.status.remaining,
            peakEndAt: snap.status.peakEndAt,
            effectEndAt: snap.status.effectEndAt,
            takenToday: snap.status.takenToday,
            targetAt: snap.targetAt,
            skippedToday: snap.skippedToday,
            pillsLeft: snap.pillsLeft,
            concentrationRatio: actual.isEmpty ? nil : DoseEngine.totalPlasma(actual, at: now, curve: snap.plasmaCurve),
            predictedPeakAt: DoseEngine.nextLocalPlasmaPeak(doses: actual, now: now, curve: snap.plasmaCurve),
            refreshedAt: now)
    }

    /// 下一个状态会变的时刻：高峰结束、药效结束、目标时刻、次日凌晨，取最早的一个
    static func nextStale(for st: DoseAttributes.ContentState, now: Date) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let candidates: [Date?] = [now.addingTimeInterval(300), tomorrow.addingTimeInterval(300),
                                   st.predictedPeakAt, st.peakEndAt, st.effectEndAt, st.targetAt]
        return candidates.compactMap { $0 }.filter { $0 > now }.min() ?? tomorrow
    }

    static func refresh(from snap: SharedSnapshot, settings: SyncedSettings) {
        guard isSupported else { report("notAuthorized"); return }
        guard settings.liveActivityEnabled else { endAll(); return }
        let now = Date()
        let st = state(from: snap, now: now)
        let content = ActivityContent(state: st, staleDate: nextStale(for: st, now: now))
        if let a = running {
            Task { await a.update(content); report("updated") }
        } else {
            // 把结束了但还没被系统清掉的旧条目收干净，避免锁屏上出现两条
            for a in Activity<DoseAttributes>.activities {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
            // 不在前台时 request 会抛错，这里静默忽略，下次进前台再来
            do {
                _ = try Activity.request(attributes: DoseAttributes(title: "药时"),
                                         content: content, pushType: nil)
                report("started")
            } catch {
                report("requestFailed", error: String(describing: error))
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
        for a in Activity<DoseAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#else
/// Live Activities are an iPhone system feature; recording remains available on Mac.
enum DoseActivityController {
    static var isSupported: Bool { false }
    static func refresh(from snap: SharedSnapshot, settings: SyncedSettings) {}
    static func endAll() {}
}
#endif
