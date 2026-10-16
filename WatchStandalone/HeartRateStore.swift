import Foundation
import HealthKit

/// Read-only heart-rate data for the watch screen. HealthKit controls sampling;
/// opening this screen does not start a workout or make measurements continuous.
@MainActor
final class HeartRateStore: ObservableObject {
    struct Reading {
        let bpm: Int
        let measuredAt: Date
    }

    enum AverageWindow: String, CaseIterable, Identifiable {
        case hour1, hour3, hour6, hour12, hour24, sinceCheckpoint

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hour1: return "近 1 小时"
            case .hour3: return "近 3 小时"
            case .hour6: return "近 6 小时"
            case .hour12: return "近 12 小时"
            case .hour24: return "近 24 小时"
            case .sinceCheckpoint: return "自检查点"
            }
        }

        var duration: TimeInterval? {
            switch self {
            case .hour1: return 3600
            case .hour3: return 3 * 3600
            case .hour6: return 6 * 3600
            case .hour12: return 12 * 3600
            case .hour24: return 24 * 3600
            case .sinceCheckpoint: return nil
            }
        }
    }

    @Published private(set) var latest: Reading?
    @Published private(set) var selectedAverageWindow: AverageWindow
    @Published private(set) var checkpointAt: Date?
    @Published private(set) var averageBPM: Int?
    @Published private(set) var averageMessage = ""
    @Published private(set) var message = "点按授权后读取心率"
    @Published private(set) var isLoading = false
    @Published private(set) var shouldOfferAuthorization = true

    /// Compatibility with the previous screen until its selector is wired.
    var averageLastHour: Int? {
        selectedAverageWindow == .hour1 ? averageBPM : nil
    }

    private enum DefaultsKey {
        static let averageWindow = "heartRate.averageWindow.v1"
        static let checkpoint = "heartRate.checkpoint.v1"
    }

    private let healthStore = HKHealthStore()
    private let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
    private var observerQuery: HKObserverQuery?
    private var refreshGeneration = 0

    init() {
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.averageWindow)
        selectedAverageWindow = AverageWindow(rawValue: saved ?? "") ?? .hour1
        checkpointAt = UserDefaults.standard.object(forKey: DefaultsKey.checkpoint) as? Date
    }

    func selectAverageWindow(_ window: AverageWindow) {
        guard selectedAverageWindow != window else { return }
        selectedAverageWindow = window
        UserDefaults.standard.set(window.rawValue, forKey: DefaultsKey.averageWindow)
        refresh()
    }

    /// A manual timestamp only. It does not assert that an event happened then.
    func setCheckpointNow() {
        let now = Date()
        checkpointAt = now
        UserDefaults.standard.set(now, forKey: DefaultsKey.checkpoint)
        if selectedAverageWindow == .sinceCheckpoint { refresh() }
    }

    /// Observe samples while the app is visible; this does not make the watch
    /// take measurements or request HealthKit background delivery.
    func startObserving() {
        guard observerQuery == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let query = HKObserverQuery(sampleType: heartRate, predicate: nil) { [weak self] _, completion, _ in
            Task { @MainActor in self?.refresh() }
            completion()
        }
        observerQuery = query
        healthStore.execute(query)
        refresh()
    }

    func stopObserving() {
        if let observerQuery { healthStore.stop(observerQuery) }
        observerQuery = nil
    }

    func requestAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "这块手表无法读取健康数据"
            shouldOfferAuthorization = false
            return
        }
        healthStore.requestAuthorization(toShare: [], read: [heartRate]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.message = "未能完成心率授权，请稍后重试"
                    self.shouldOfferAuthorization = true
                } else {
                    // For privacy, HealthKit does not disclose whether read access was denied.
                    // An empty result must not be described as confirmed permission.
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "这块手表无法读取健康数据"
            shouldOfferAuthorization = false
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        averageBPM = nil
        averageMessage = ""
        let end = Date()
        let start = selectedAverageWindow.duration.map { end.addingTimeInterval(-$0) } ?? checkpointAt
        let latestQuery = HKSampleQuery(sampleType: heartRate,
                                        predicate: nil,
                                        limit: 1,
                                        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { [weak self] _, samples, error in
            let sample = (samples as? [HKQuantitySample])?.first
            Task { @MainActor in
                guard let self, self.refreshGeneration == generation else { return }
                if error != nil {
                    self.latest = nil
                    self.message = "暂时无法读取心率，请检查健康权限后重试"
                    self.shouldOfferAuthorization = true
                } else if let sample {
                    self.latest = Reading(bpm: Int(sample.quantity.doubleValue(for: self.beatsPerMinute).rounded()),
                                          measuredAt: sample.endDate)
                    self.message = ""
                    self.shouldOfferAuthorization = false
                } else {
                    self.latest = nil
                    self.message = "没有可读的心率记录；请检查健康权限或稍后再试"
                    self.shouldOfferAuthorization = true
                }
                self.isLoading = false
            }
        }
        healthStore.execute(latestQuery)

        guard let start else {
            averageBPM = nil
            averageMessage = "先设置检查点，再查看此后的平均心率"
            return
        }
        guard start < end else {
            averageBPM = nil
            averageMessage = "检查点刚设置，尚无可读心率记录"
            return
        }
        let interval = HKQuery.predicateForSamples(withStart: start, end: end)
        let averageQuery = HKStatisticsQuery(quantityType: heartRate,
                                             quantitySamplePredicate: interval,
                                             options: .discreteAverage) { [weak self] _, statistics, error in
            Task { @MainActor in
                guard let self, self.refreshGeneration == generation else { return }
                self.averageBPM = statistics?.averageQuantity().map {
                    Int($0.doubleValue(for: self.beatsPerMinute).rounded())
                }
                if error != nil {
                    self.averageMessage = "暂时无法读取平均心率"
                } else if self.averageBPM == nil {
                    self.averageMessage = "所选时间段没有可读心率记录"
                } else {
                    self.averageMessage = ""
                }
            }
        }
        healthStore.execute(averageQuery)
    }
}
