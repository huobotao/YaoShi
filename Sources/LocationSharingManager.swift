import Foundation
import Combine
import CoreLocation
import Network
import UIKit

/// Opt-in, device-local collection. Location never enters medication/iCloud files.
/// Uploads use the paired space's existing authenticated, end-to-end encrypted relay.
@MainActor
final class LocationSharingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationSharingManager()

    @Published private(set) var enabled = false
    @Published private(set) var status = "位置共享未开启"
    @Published private(set) var authorizationText = "尚未检查定位权限"
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastSample: LocationSample?
    @Published private(set) var received: [LocationReceivedBatch] = []
    @Published private(set) var isWorking = false
    @Published private(set) var discardedSampleCount = 0

    private var state = LocationSharingState()
    private let location = CLLocationManager()
    private let network = NWPathMonitor()
    private var transport = "unknown"
    private var timer: Timer?
    private var uploadTask: Task<Void, Never>?
    private var generation = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var loadFailed = false
    private var bootstrapped = false
    private var lastAttempt: Date?
    private let consentKey = "yaoshi.location-sharing.consent.v1"
    private let file: URL
    private let session: URLSession

    private override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationSharing", isDirectory: true)
        file = directory.appendingPathComponent("state-v1.json")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config)
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(LocationSharingState.self, from: Data(contentsOf: file))
            }
            // A persisted opt-out always overrides an older snapshot after a disk failure.
            if !UserDefaults.standard.bool(forKey: consentKey) { state.pause() }
            state.prune(now: Date())
        } catch {
            loadFailed = true
            status = "位置缓存无法读取，已停止采集；原文件保留"
        }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 10
        location.activityType = .other
        location.pausesLocationUpdatesAutomatically = false
        #if !targetEnvironment(macCatalyst)
        location.allowsBackgroundLocationUpdates = true
        // Keep Apple's default presentation for Always authorization. System
        // permission prompts, When-In-Use indicators and privacy reminders remain.
        location.showsBackgroundLocationIndicator = false
        #endif
        network.pathUpdateHandler = { [weak self] path in
            let name: String
            if path.status != .satisfied { name = "offline" }
            else if path.usesInterfaceType(.wifi) { name = "wifi" }
            else if path.usesInterfaceType(.cellular) { name = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { name = "ethernet" }
            else { name = "other" }
            Task { @MainActor in self?.transport = name }
        }
        network.start(queue: DispatchQueue(label: "yaoshi.location.network"))
        publish()
        updateAuthorization()
    }

    func foreground() {
        guard !loadFailed else { return }
        bootstrapped = true
        resetReceivingSpaceIfNeeded()
        updateAuthorization()
        if state.enabled {
            guard credentialsStillMatch() else { stopSharing(); status = "配对已改变，请重新确认位置共享"; return }
            resumeIfAuthorized()
            scheduleUpload(force: false)
        }
    }

    func startSharing() {
        #if targetEnvironment(macCatalyst)
        status = "请在 iPhone 上开启位置共享；此设备可查看收到的位置"
        return
        #else
        guard !loadFailed else { return }
        guard let credentials = PartnerSharingCoordinator.shared.credentials[.yaoShi] else {
            status = "请先在伴侣共享中配对，再开启位置共享"
            return
        }
        guard !state.enabled else { foreground(); return }
        state.pause()
        state.enabled = true
        state.boundSpaceID = credentials.spaceID
        state.boundServer = credentials.baseURL.absoluteString
        state.boundSharingIdentity = credentials.locationSharingIdentity
        UserDefaults.standard.set(true, forKey: consentKey)
        bootstrapped = true
        guard persist() else { failClosed(); return }
        publish()
        if location.authorizationStatus == .notDetermined {
            status = "等待你允许定位"
            location.requestWhenInUseAuthorization()
        } else { resumeIfAuthorized() }
        #endif
    }

    func requestAlwaysPermission() {
        #if !targetEnvironment(macCatalyst)
        guard state.enabled else { return }
        if location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
        #endif
    }

    func stopSharing() {
        generation = UUID()
        uploadTask?.cancel()
        uploadTask = nil
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        location.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.set(false, forKey: consentKey)
        state.pause()
        isWorking = false
        finishBackgroundTask()
        let saved = persist()
        status = saved ? "已停止采集，未发送队列已清除；已发出的数据无法撤回" : "已停止采集；本机缓存清理失败，重新打开也不会继续发送"
        publish()
    }

    /// Explicit refresh is the only path that sends a partial batch before five minutes.
    func refresh() async {
        if state.enabled {
            scheduleUpload(force: true)
            await uploadTask?.value
        }
        await MedicationShareRepository.shared.sync()
    }

    @discardableResult
    func receive(_ batch: LocationBatch, author: String, receivedAt: Date) -> Bool {
        guard !loadFailed, batch.isValid else { return false }
        guard PartnerSharingCoordinator.shared.credentials[.yaoShi] != nil else { return false }
        resetReceivingSpaceIfNeeded()
        // Relay also returns the sender's own events. Do not show them as partner locations.
        guard batch.deviceID != state.deviceID else { return true }
        let previous = state
        guard state.receive(batch, author: author, now: receivedAt) else { return false }
        guard persist() else { state = previous; publish(); return false }
        publish()
        return true
    }

    private func resetReceivingSpaceIfNeeded() {
        let credentials = PartnerSharingCoordinator.shared.credentials[.yaoShi]
        guard state.receivedSharingIdentity != credentials?.locationSharingIdentity else { return }
        state.receivedBatches.removeAll()
        state.receivedSpaceID = credentials?.spaceID
        state.receivedServer = credentials?.baseURL.absoluteString
        state.receivedSharingIdentity = credentials?.locationSharingIdentity
        _ = persist()
        publish()
    }

    private var mayUpload: Bool {
        let auth = location.authorizationStatus
        return state.enabled && (auth == .authorizedAlways || auth == .authorizedWhenInUse)
    }

    private func credentialsStillMatch() -> Bool {
        guard let credentials = PartnerSharingCoordinator.shared.credentials[.yaoShi] else { return false }
        return state.boundSharingIdentity == credentials.locationSharingIdentity
    }

    private func resumeIfAuthorized() {
        guard state.enabled, bootstrapped, !loadFailed else { return }
        updateAuthorization()
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            location.startUpdatingLocation()
            status = "正在记录；约每五分钟尝试批量上传"
            if timer == nil {
                // This timer is opportunistic, never an iOS background wake-up guarantee.
                timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.scheduleUpload(force: false) }
                }
            }
        case .denied, .restricted:
            stopSharing()
            status = "定位未获允许，共享已停止；可在系统设置中修改权限"
        case .notDetermined: status = "等待定位授权；尚未采集"
        @unknown default: status = "定位权限状态未知，尚未开始"
        }
    }

    private func updateAuthorization() {
        switch location.authorizationStatus {
        case .notDetermined: authorizationText = "尚未授权"
        case .restricted: authorizationText = "受系统限制"
        case .denied: authorizationText = "未允许定位"
        case .authorizedAlways: authorizationText = "始终允许"
        case .authorizedWhenInUse: authorizationText = "使用期间允许"
        @unknown default: authorizationText = "未知"
        }
        if location.accuracyAuthorization == .reducedAccuracy { authorizationText += " · 大致位置" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateAuthorization()
            if self.bootstrapped { self.resumeIfAuthorized() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.record(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.state.enabled else { return }
            self.status = "暂未获得新位置；已有缓存保留"
        }
    }

    private func record(_ locations: [CLLocation]) {
        guard state.enabled, bootstrapped, !loadFailed else { return }
        guard credentialsStillMatch() else { stopSharing(); status = "配对已改变，共享已停止"; return }
        let now = Date()
        var changed = false
        for point in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            // Core Location may first deliver a cached fix. Never label it a fresh sample.
            guard abs(now.timeIntervalSince(point.timestamp)) <= 120,
                  point.sourceInformation?.isSimulatedBySoftware != true else { continue }
            let sample = LocationSample(id: UUID(), sampledAt: point.timestamp,
                latitude: point.coordinate.latitude, longitude: point.coordinate.longitude,
                horizontalAccuracy: point.horizontalAccuracy,
                altitude: point.verticalAccuracy >= 0 ? point.altitude : nil,
                verticalAccuracy: point.verticalAccuracy >= 0 ? point.verticalAccuracy : nil,
                speed: point.speed >= 0 ? point.speed : nil,
                course: point.course >= 0 ? point.course : nil,
                networkTransport: transport)
            if state.record(sample) { changed = true }
        }
        if changed {
            guard persist() else { failClosed(); return }
            publish()
        }
        scheduleUpload(force: false)
    }

    private func scheduleUpload(force: Bool) {
        guard mayUpload, !loadFailed, !isWorking, bootstrapped else { return }
        guard credentialsStillMatch() else { stopSharing(); status = "配对已改变，共享已停止"; return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 30 { return }
        _ = state.stageBatch(now: Date(), force: force)
        guard !state.pendingBatches.isEmpty else { return }
        guard persist() else { failClosed(); return }
        guard let credentials = PartnerSharingCoordinator.shared.credentials[.yaoShi] else { return }
        let currentGeneration = generation
        lastAttempt = Date()
        isWorking = true
        publish()
        #if !targetEnvironment(macCatalyst)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "位置批次上传") { [weak self] in
            Task { @MainActor in
                self?.uploadTask?.cancel()
                self?.finishBackgroundTask()
            }
        }
        #endif
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.isWorking = false
                    self.finishBackgroundTask()
                    self.uploadTask = nil
                    self.publish()
                }
            }
            do {
                let client = PartnerSyncClient(session: self.session)
                // Bound work per execution; remaining batches stay on disk for the next opportunity.
                for _ in 0..<4 {
                    try Task.checkCancellation()
                    guard self.mayUpload, self.generation == currentGeneration,
                          self.credentialsStillMatch(), let batch = self.state.pendingBatches.first else { break }
                    let payload = try JSONEncoder().encode(batch)
                    _ = try await client.append(payload, eventID: batch.id, createdAt: batch.createdAt,
                                                notifyPartner: false, credentials: credentials)
                    guard self.state.enabled, self.generation == currentGeneration else { return }
                    self.state.pendingBatches.removeAll { $0.id == batch.id }
                    self.state.lastUploadAt = Date()
                    guard self.persist() else { self.failClosed(); return }
                    self.status = "共享服务已接收位置批次；不代表对方已经查看"
                }
            } catch {
                if self.state.enabled, self.generation == currentGeneration {
                    self.status = "上传尚未完成；位置保留在本机，稍后重试"
                }
            }
        }
    }

    private func finishBackgroundTask() {
        #if !targetEnvironment(macCatalyst)
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        #endif
    }

    private func failClosed() {
        location.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        uploadTask?.cancel()
        UserDefaults.standard.set(false, forKey: consentKey)
        state.enabled = false
        status = "位置缓存保存失败，已停止共享；未确认上传的记录保留"
        publish()
    }

    @discardableResult
    private func persist() -> Bool {
        guard !loadFailed else { return false }
        do {
            state.prune(now: Date())
            let data = try JSONEncoder().encode(state)
            // Only this opt-in location cache remains accessible after first unlock.
            // Medication storage protection is unchanged.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            status = "位置缓存保存失败"
            return false
        }
    }

    private func publish() {
        enabled = state.enabled && !loadFailed
        pendingCount = state.pendingSamples.count + state.pendingBatches.reduce(0) { $0 + $1.samples.count }
        lastUploadAt = state.lastUploadAt
        lastSample = state.localSamples.max(by: { $0.sampledAt < $1.sampledAt })
        received = state.receivedBatches
        discardedSampleCount = state.discardedSampleCount
    }
}
