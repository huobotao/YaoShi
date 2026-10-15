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

    @Published private(set) var latest: Reading?
    @Published private(set) var averageLastHour: Int?
    @Published private(set) var message = "点按授权后读取心率"
    @Published private(set) var isLoading = false
    @Published private(set) var shouldOfferAuthorization = true

    private let healthStore = HKHealthStore()
    private let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
    private var observerQuery: HKObserverQuery?

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
        isLoading = true
        let end = Date()
        let start = end.addingTimeInterval(-3600)
        let recentHour = HKQuery.predicateForSamples(withStart: start, end: end)
        let latestQuery = HKSampleQuery(sampleType: heartRate,
                                        predicate: nil,
                                        limit: 1,
                                        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { [weak self] _, samples, error in
            let sample = (samples as? [HKQuantitySample])?.first
            Task { @MainActor in
                guard let self else { return }
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
        let averageQuery = HKStatisticsQuery(quantityType: heartRate,
                                             quantitySamplePredicate: recentHour,
                                             options: .discreteAverage) { [weak self] _, statistics, _ in
            Task { @MainActor in
                guard let self else { return }
                self.averageLastHour = statistics?.averageQuantity().map {
                    Int($0.doubleValue(for: self.beatsPerMinute).rounded())
                }
            }
        }
        healthStore.execute(latestQuery)
        healthStore.execute(averageQuery)
    }
}
