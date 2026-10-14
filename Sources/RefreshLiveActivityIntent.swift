#if !targetEnvironment(macCatalyst)
import AppIntents
import Foundation

/// User-triggered, local recalculation. This does not schedule background execution.
struct RefreshDoseActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "刷新浓度估算"
    static var description = IntentDescription("根据本机已保存的记录重新计算锁屏和灵动岛的估算值，不新增服药记录。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if YAOSHI_APP
        guard let snapshot = SharedStore.load(),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONDecoder().decode(SyncedSettings.self, from: data) else {
            throw RefreshError.localDataUnavailable
        }
        await DoseActivityController.refreshExisting(from: snapshot, settings: settings)
        #else
        // LiveActivityIntent runs in the containing app; never claim success in the extension.
        throw RefreshError.localDataUnavailable
        #endif
        return .result()
    }

    private enum RefreshError: LocalizedError {
        case localDataUnavailable
        var errorDescription: String? { "暂时无法读取本机数据，请打开药时后重试。" }
    }
}
#endif
