#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import CoreLocation
import Combine

/// Default-enabled, local-only background refresh. Location delivery may
/// keep this process runnable, but neither delivery nor a 30-second cadence is guaranteed.
/// No coordinate, medication value, device identifier or token is retained by this service.
/// Diagnostic session IDs are random per process and never identify a person or device.
@MainActor
final class BackgroundRefreshExperiment: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundRefreshExperiment()

    @Published private(set) var statusText = "后台刷新未开启"
    @Published private(set) var isRunning = false
    @Published private(set) var needsSettings = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var alwaysAuthorizationMessage = "后台刷新默认开启；可申请始终允许定位。"
    @Published private(set) var pendingAlwaysAuthorization = false

    var authorizationText: String {
        switch authorizationStatus {
        case .notDetermined: return "尚未选择"
        case .authorizedWhenInUse: return "使用 App 期间"
        case .authorizedAlways: return "始终允许"
        case .denied: return "不允许"
        case .restricted: return "受到系统限制"
        @unknown default: return "未知"
        }
    }

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
    private let enabledKey = "backgroundRefreshEnabled"
    var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private var locationStarted = false
    private var lastPublishUptime: TimeInterval?
    private var foregroundPublishes = 0
    private var backgroundPublishes = 0
    private var publishEvents: [[String: Any]] = []
    private let processSessionID = UUID().uuidString
    private var runtimeEvents: [[String: Any]] = []
    private var locationCallbackCount = 0
    private var lastLocationCallbackAt: TimeInterval?
    private var lastCallbackDiagnosticUptime: TimeInterval?
    private var backgroundSession: CLBackgroundActivitySession?
    private var sessionDiagnosticsTask: Task<Void, Never>?
    private var sessionDiagnostics: [String: Bool] = [:]

    private override init() {
        super.init()
        // Observe transitions without a timer or background task that could mask suspension.
        let notifications = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification,
                     UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification,
                     UIApplication.willTerminateNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            notifications.addObserver(self, selector: #selector(runtimeNotification(_:)), name: name, object: nil)
        }
        // Activation occurs once UIKit is foreground and the publisher is configured.
    }

    /// The caller supplies a weak Store capture, so this singleton never owns a Store.
    func configure(publish: @escaping @MainActor () -> Void) {
        guard isExperimentBuild else { return }
        self.publish = publish
        ensureLifecycle()
    }

    func start(publish: @escaping @MainActor () -> Void) {
        configure(publish: publish)
        start()
    }

    /// Always authorization is a separate explicit action. Never chain an
    /// automatic upgrade request after the initial When In Use prompt.
    func requestAlwaysAuthorization() {
        guard isExperimentBuild else { return }
        guard UIApplication.shared.applicationState == .active else {
            alwaysAuthorizationMessage = "请在药时前台申请定位权限。"
            return
        }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alwaysAuthorizationMessage = "此版本未配置始终定位权限说明。"
            return
        }
        ensureLifecycle()
        guard !needsSettings else {
            alwaysAuthorizationMessage = "请打开系统设置查看定位权限；系统定位服务也需要开启。"
            return
        }
        switch authorizationStatus {
        case .notDetermined:
            pendingAlwaysAuthorization = true
            alwaysAuthorizationMessage = "请先允许使用 App 期间定位，再点一次“申请始终允许定位”。"
            if !pendingStart { manager.requestWhenInUseAuthorization() }
        case .authorizedWhenInUse:
            pendingAlwaysAuthorization = false
            alwaysAuthorizationMessage = "已请求升级为始终允许；若系统没有弹窗，请在系统设置的定位权限中查看。选择“允许一次”时可能无法直接升级。"
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            pendingAlwaysAuthorization = false
            alwaysAuthorizationMessage = "已允许始终定位；后台刷新默认开启，无自动停止时限，系统仍可能暂停运行。"
        case .denied, .restricted:
            alwaysAuthorizationMessage = "请打开系统设置查看定位权限。"
        @unknown default:
            alwaysAuthorizationMessage = "当前系统权限状态不支持申请。"
        }
    }

    /// Start automatically in foreground or from the local Settings control.
    func start() {
        guard isExperimentBuild else { statusText = "此版本未启用后台刷新"; return }
        UserDefaults.standard.set(true, forKey: enabledKey)
        guard !isRunning else { return }
        guard UIApplication.shared.applicationState == .active else {
            statusText = "等待药时回到前台自动开启"
            return
        }
        guard publish != nil else { statusText = "后台刷新尚未连接刷新入口"; return }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("location"),
              let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "此版本未配置后台定位权限"
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
            statusText = "等待定位授权；允许后自动开启后台刷新"
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginSessionIfForeground()
        case .denied, .restricted:
            stopWithStatus("定位权限未获允许，后台刷新未启动", event: "authorizationDenied")
            needsSettings = true
        @unknown default:
            stopWithStatus("当前定位权限不支持此后台刷新", event: "authorizationUnknown")
        }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        stopWithStatus("后台刷新已关闭", event: "userStopped")
    }

    /// Resume the default-enabled service after launch or permission restoration.
    func ensureLifecycle() {
        guard isExperimentBuild else { return }
        authorizationStatus = manager.authorizationStatus
        needsSettings = !CLLocationManager.locationServicesEnabled() || authorizationStatus == .denied || authorizationStatus == .restricted
        updateAlwaysAuthorizationMessage()
        if isRunning && needsSettings {
            stopWithStatus("定位服务或权限不可用，后台刷新停止", event: "locationUnavailable")
            return
        }
        if pendingStart { beginSessionIfForeground() }
        else if isEnabled && !isRunning && !needsSettings && publish != nil && UIApplication.shared.applicationState == .active { start() }
    }

    private func beginSessionIfForeground() {
        guard pendingStart,
              authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        guard UIApplication.shared.applicationState == .active else {
            statusText = "已获定位权限，等待药时回到前台自动开启"
            return
        }
        pendingStart = false
        locationStarted = true
        needsSettings = false
        foregroundPublishes = 0; backgroundPublishes = 0; publishEvents = []
        lastPublishUptime = nil
        // This candidate explicitly requests continuous high-accuracy delivery.
        // It costs more energy and remains subject to system scheduling and authorization.
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        startBackgroundSession()
        manager.startUpdatingLocation()
        statusText = "后台刷新运行中（无时限）；系统可能暂停或降低频率"
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishIfDue(source: "timer") }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
        record(event: "started")
        publishIfDue(source: "started")
    }

    private func startBackgroundSession() {
        guard backgroundSession == nil else { return }
        let session = CLBackgroundActivitySession()
        backgroundSession = session
        // Retaining a session is intent, not evidence that the system accepted it.
        // iOS 18+ diagnostics explain why a session may be suspended.
        if #available(iOS 18.0, *) {
            sessionDiagnosticsTask = Task { @MainActor [weak self, session] in
                do {
                    for try await diagnostic in session.diagnostics {
                        guard !Task.isCancelled, let self else { return }
                        self.sessionDiagnostics = [
                            "authorizationDenied": diagnostic.authorizationDenied,
                            "authorizationDeniedGlobally": diagnostic.authorizationDeniedGlobally,
                            "authorizationRestricted": diagnostic.authorizationRestricted,
                            "insufficientlyInUse": diagnostic.insufficientlyInUse,
                            "serviceSessionRequired": diagnostic.serviceSessionRequired,
                            "authorizationRequestInProgress": diagnostic.authorizationRequestInProgress
                        ]
                        self.record(event: "backgroundSessionDiagnostic")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // Do not record error descriptions, which may contain private context.
                    self?.record(event: "backgroundSessionDiagnosticEnded",
                                 details: ["errorCode": (error as NSError).code])
                }
            }
        }
    }

    @objc nonisolated private func runtimeNotification(_ notification: Notification) {
        let name = notification.name.rawValue
        Task { @MainActor [weak self] in
            guard let self, self.isExperimentBuild else { return }
            self.record(event: "lifecycle", details: ["notification": name])
        }
    }

    private func publishIfDue(source: String) {
        guard isRunning, locationStarted else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastPublishUptime, uptime - lastPublishUptime < 30 { return }
        guard let publish else { stopWithStatus("刷新入口已断开，后台刷新停止", event: "missingPublisher"); return }
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
        sessionDiagnosticsTask?.cancel(); sessionDiagnosticsTask = nil
        backgroundSession?.invalidate(); backgroundSession = nil
        if locationStarted {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        locationStarted = false; pendingStart = false; isRunning = false
        lastPublishUptime = nil
        statusText = status
        record(event: event)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged() }
    }

    private func authorizationChanged() {
        authorizationStatus = manager.authorizationStatus
        record(event: "authorizationChanged")
        needsSettings = !CLLocationManager.locationServicesEnabled() || authorizationStatus == .denied || authorizationStatus == .restricted
        updateAlwaysAuthorizationMessage()
        if isRunning && needsSettings {
            stopWithStatus("定位权限已撤销，后台刷新停止", event: "authorizationRevoked")
        } else {
            ensureLifecycle()
        }
    }

    private func updateAlwaysAuthorizationMessage() {
        if authorizationStatus == .authorizedAlways {
            pendingAlwaysAuthorization = false
            alwaysAuthorizationMessage = "已允许始终定位；后台刷新默认开启，无自动停止时限，系统仍可能暂停运行。"
        } else if pendingAlwaysAuthorization && authorizationStatus == .authorizedWhenInUse {
            alwaysAuthorizationMessage = "已获使用 App 期间定位权限。请再点一次“申请始终允许定位”继续；不会自动再次弹窗。"
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            pendingAlwaysAuthorization = false
            alwaysAuthorizationMessage = "定位未获允许，请打开系统设置查看。"
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately ignore every coordinate, without even transferring it into a task.
        Task { @MainActor [weak self] in self?.locationReceived() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        let code = (error as NSError).code
        let isCoreLocationError = (error as NSError).domain == kCLErrorDomain
        Task { @MainActor [weak self] in
            self?.locationFailed(denied: denied, code: code, isCoreLocationError: isCoreLocationError)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.record(event: "locationUpdatesPaused") }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.record(event: "locationUpdatesResumed") }
    }

    private func locationReceived() {
        guard isRunning, locationStarted else { return }
        locationCallbackCount += 1
        lastLocationCallbackAt = Date().timeIntervalSince1970
        publishIfDue(source: "locationCallback")
        // Persist callback health at most every 30 seconds, never every GPS fix.
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - (lastCallbackDiagnosticUptime ?? -.infinity) >= 30 {
            lastCallbackDiagnosticUptime = uptime
            record(event: "locationCallback")
        }
    }

    private func locationFailed(denied: Bool, code: Int, isCoreLocationError: Bool) {
        record(event: "locationError", details: ["errorCode": code, "isCoreLocationError": isCoreLocationError])
        guard isRunning else { return }
        if denied {
            needsSettings = true
            stopWithStatus("系统拒绝定位，后台刷新停止", event: "locationDenied")
        } else {
            statusText = "后台刷新运行中，暂未取得定位回调；刷新频率不保证"
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

    private func record(event: String, details: [String: Any] = [:]) {
        var entry = details
        entry["event"] = event
        entry["at"] = Date().timeIntervalSince1970
        entry["applicationState"] = applicationStateName
        runtimeEvents.append(entry)
        if runtimeEvents.count > 64 { runtimeEvents.removeFirst(runtimeEvents.count - 64) }
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let diagnostics: [String: Any] = [
            "event": event, "checkedAt": Date().timeIntervalSince1970,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "processSessionID": processSessionID,
            "systemUptime": ProcessInfo.processInfo.systemUptime,
            "locationStarted": locationStarted,
            "backgroundSessionRetained": backgroundSession != nil,
            "backgroundSessionDiagnostics": sessionDiagnostics,
            "accuracyAuthorizationRawValue": manager.accuracyAuthorization.rawValue,
            "desiredAccuracy": manager.desiredAccuracy,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalStateRawValue": ProcessInfo.processInfo.thermalState.rawValue,
            "locationCallbackCount": locationCallbackCount,
            "lastLocationCallbackAt": lastLocationCallbackAt.map { $0 as Any } ?? NSNull(),
            "runtimeEvents": runtimeEvents,
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
            // Diagnostic disk failures must not expose coordinates or interrupt refresh.
        }
    }
}
#endif
