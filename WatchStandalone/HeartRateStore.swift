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

    private let healthStore = HKHealthStore()
    private let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())

    func requestAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "这块手表无法读取健康数据"
            return
        }
        healthStore.requestAuthorization(toShare: [], read: [heartRate]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.message = "心率授权未完成：\(error.localizedDescription)"
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
                if let error {
                    self.latest = nil
                    self.message = "读取心率失败：\(error.localizedDescription)"
                } else if let sample {
                    self.latest = Reading(bpm: Int(sample.quantity.doubleValue(for: self.beatsPerMinute).rounded()),
                                          measuredAt: sample.endDate)
                    self.message = ""
                } else {
                    self.latest = nil
                    self.message = "没有可读的心率记录；请检查健康权限或稍后再试"
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
