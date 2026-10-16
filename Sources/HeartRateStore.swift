import Foundation
import HealthKit

/// Reads heart-rate samples already recorded in Health. This does not start a
/// workout or ask the watch for a new measurement.
@MainActor
final class HeartRateStore: ObservableObject {
    @Published private(set) var latestBPM: Int?
    @Published private(set) var latestAt: Date?
    @Published private(set) var hourAverageBPM: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let healthStore = HKHealthStore()
    private let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private var refreshGeneration = 0

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() {
        guard available else {
            message = "这台设备无法读取健康数据。"
            return
        }
        healthStore.requestAuthorization(toShare: [], read: [heartRate]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.message = "无法请求心率读取权限：\(error.localizedDescription)"
                } else {
                    // HealthKit does not disclose whether read access was denied.
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        guard available else {
            message = "这台设备无法读取健康数据。"
            return
        }
        isLoading = true
        message = nil
        hourAverageBPM = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let now = Date()
        let latestQuery = HKSampleQuery(sampleType: heartRate,
                                        predicate: nil,
                                        limit: 1,
                                        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { [weak self] _, samples, error in
            let sample = (samples as? [HKQuantitySample])?.first
            let bpm = sample.map { Int($0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded()) }
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.latestBPM = bpm
                self.latestAt = sample?.endDate
                self.isLoading = false
                if let error {
                    self.message = "心率读取失败：\(error.localizedDescription)"
                } else if sample == nil {
                    self.message = "暂无可读取的心率记录；也可能未授予读取权限。"
                }
            }
        }
        healthStore.execute(latestQuery)

        let hourStart = now.addingTimeInterval(-3600)
        let averageQuery = HKStatisticsQuery(quantityType: heartRate,
                                             quantitySamplePredicate: HKQuery.predicateForSamples(withStart: hourStart, end: now),
                                             options: .discreteAverage) { [weak self] _, statistics, _ in
            let bpm = statistics?.averageQuantity().map {
                Int($0.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
            }
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                self.hourAverageBPM = bpm
            }
        }
        healthStore.execute(averageQuery)
    }
}
