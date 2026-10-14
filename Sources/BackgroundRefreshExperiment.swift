#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import CoreLocation
import Combine

/// An explicitly started, local-only diagnostic experiment. Location delivery may
/// keep this process runnable, but neither delivery nor a 30-second cadence is guaranteed.
/// No coordinate, medication value, identifier or token is retained by this service.
@MainActor
final class BackgroundRefreshExperiment: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundRefreshExperiment()

    @Published private(set) var statusText = "实验未开启"
    @Published private(set) var isRunning = false
    @Published private(set) var endsAt: Date?
    @Published private(set) var needsSettings = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    static var diagnosticFilename: String { "background-refresh-experiment-status.json" }
    private var isExperimentBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "YaoShiBackgroundLocationExperiment") as? Bool == true
    }
    private var publish: (@MainActor () -> Void)?
    private var timer: Timer?
    private var pendingStart = false
    private var locationStarted = false
    private var deadlineUptime: TimeInterval?
    private var lastPublishUptime: TimeInterval?
    private var foregroundPublishes = 0
    private var backgroundPublishes = 0
    private var publishEvents: [[String: Any]] = []

    private override init() {
        super.init()
        // Deliberately do not restore a running experiment or request permission at launch.
    }

    /// The caller supplies a weak Store capture, so this singleton never owns a Store.
    func configure(publish: @escaping @MainActor () -> Void) {
        guard isExperimentBuild else { return }
        self.publish = publish
    }

    func start(publish: @escaping @MainActor () -> Void) {
        configure(publish: publish)
        start()
    }

    /// Call only from the user's explicit experiment button while the app is foreground.
    func start() {
        guard isExperimentBuild else { statusText = "此版本未启用定位刷新实验"; return }
        guard !isRunning else { return }
        guard UIApplication.shared.applicationState == .active else {
            statusText = "请在药时前台点击开始实验"
            return
        }
        guard publish != nil else { statusText = "实验尚未连接刷新入口"; return }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("location"),
              let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "此版本未配置后台定位实验权限"
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            needsSettings = true
            statusText = "系统定位服务未开启"
            return
        }
        authorizationStatus = manager.authorizationStatus
        pendingStart = true
        isRunning = true
        switch authorizationStatus {
        case .notDetermined:
            statusText = "等待定位授权；允许后开始十五分钟实验"
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginSessionIfForeground()
        case .denied, .restricted:
            stopWithStatus("定位权限未获允许，实验未启动", event: "authorizationDenied")
            needsSettings = true
        @unknown default:
            stopWithStatus("当前定位权限不支持此实验", event: "authorizationUnknown")
        }
    }

    func stop() {
        stopWithStatus("实验已停止", event: "userStopped")
    }

    /// Call on scene/lifecycle changes. Returning to foreground also enforces an
    /// expired deadline before any publish; a suspended process cannot run timer code.
    func ensureLifecycle() {
        guard isExperimentBuild else { return }
        authorizationStatus = manager.authorizationStatus
        needsSettings = !CLLocationManager.locationServicesEnabled() || authorizationStatus == .denied || authorizationStatus == .restricted
        if expireIfNeeded() { return }
        if isRunning && needsSettings {
            stopWithStatus("定位服务或权限不可用，实验停止", event: "locationUnavailable")
            return
        }
        if pendingStart { beginSessionIfForeground() }
    }

    private func beginSessionIfForeground() {
        guard pendingStart,
              authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        guard UIApplication.shared.applicationState == .active else {
            statusText = "已获定位权限，等待药时回到前台开始实验"
            return
        }
        pendingStart = false
        locationStarted = true
        needsSettings = false
        foregroundPublishes = 0; backgroundPublishes = 0; publishEvents = []
        lastPublishUptime = nil
        deadlineUptime = ProcessInfo.processInfo.systemUptime + 15 * 60
        endsAt = Date().addingTimeInterval(15 * 60)
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        statusText = "十五分钟定位刷新实验运行中；系统可能暂停或降低频率"
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishIfDue(source: "timer") }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
        record(event: "started")
        publishIfDue(source: "started")
    }

    @discardableResult
    private func expireIfNeeded() -> Bool {
        guard let deadlineUptime, ProcessInfo.processInfo.systemUptime >= deadlineUptime else { return false }
        stopWithStatus("十五分钟实验已到期并停止", event: "expired")
        return true
    }

    private func publishIfDue(source: String) {
        guard isRunning, locationStarted, !expireIfNeeded() else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastPublishUptime, uptime - lastPublishUptime < 30 { return }
        guard let publish else { stopWithStatus("刷新入口已断开，实验停止", event: "missingPublisher"); return }
        lastPublishUptime = uptime
        let background = UIApplication.shared.applicationState == .background
        publish()
        if background { backgroundPublishes += 1 } else { foregroundPublishes += 1 }
        publishEvents.append(["at": Date().timeIntervalSince1970,
                              "applicationState": applicationStateName,
                              "source": source])
        if publishEvents.count > 64 { publishEvents.removeFirst(publishEvents.count - 64) }
        record(event: "published")
    }

    private func stopWithStatus(_ status: String, event: String) {
        timer?.invalidate(); timer = nil
        if locationStarted {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        locationStarted = false; pendingStart = false; isRunning = false
        deadlineUptime = nil; endsAt = nil; lastPublishUptime = nil
        statusText = status
        record(event: event)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged() }
    }

    private func authorizationChanged() {
        authorizationStatus = manager.authorizationStatus
        needsSettings = !CLLocationManager.locationServicesEnabled() || authorizationStatus == .denied || authorizationStatus == .restricted
        if isRunning && needsSettings {
            stopWithStatus("定位权限已撤销，实验停止", event: "authorizationRevoked")
        } else if pendingStart {
            beginSessionIfForeground()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately ignore every coordinate, without even transferring it into a task.
        Task { @MainActor [weak self] in self?.publishIfDue(source: "locationCallback") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor [weak self] in self?.locationFailed(denied: denied) }
    }

    private func locationFailed(denied: Bool) {
        if expireIfNeeded() { return }
        guard isRunning else { return }
        if denied {
            needsSettings = true
            stopWithStatus("系统拒绝定位，实验停止", event: "locationDenied")
        } else {
            statusText = "实验运行中，暂未取得定位回调；刷新频率不保证"
            record(event: "locationCallbackUnavailable")
        }
    }

    private var applicationStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func record(event: String) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let diagnostics: [String: Any] = [
            "event": event, "checkedAt": Date().timeIntervalSince1970,
            "isRunning": isRunning, "authorizationRawValue": authorizationStatus.rawValue,
            "applicationState": applicationStateName,
            "foregroundPublishCount": foregroundPublishes, "backgroundPublishCount": backgroundPublishes,
            "publishEvents": publishEvents
        ]
        let url = directory.appendingPathComponent(Self.diagnosticFilename)
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: .sortedKeys) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Diagnostic disk failures must not expose coordinates or extend the session.
        }
    }
}
#endif
