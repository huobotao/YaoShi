import Foundation
import UserNotifications

/// 用户按需服药：App 不请求通知权限，也不安排服药、库存或配药提醒。
/// 启动、回到前台和保存记录时清理旧版本已经安排的通知。
enum Notifier {
    static let center = UNUserNotificationCenter.current()

    static func configure() {
        cancelAll()
    }

    static func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0) { _ in }
        // 读取系统实际状态，供升级后的真机核验；不记录通知内容或健康数据。
        center.getPendingNotificationRequests { pending in
            center.getDeliveredNotifications { delivered in
                writeDiagnostics(pendingCount: pending.count, deliveredCount: delivered.count)
            }
        }
    }

    private struct Diagnostics: Encodable {
        let checkedAt: Date
        let pendingCount: Int
        let deliveredCount: Int
        let policyDisabled = true
    }

    private static func writeDiagnostics(pendingCount: Int, deliveredCount: Int) {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return }
        let diagnostics = Diagnostics(checkedAt: Date(), pendingCount: pendingCount,
                                      deliveredCount: deliveredCount)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(diagnostics)
            try data.write(to: documents.appendingPathComponent("notificationdiagnostics.json"),
                           options: .atomic)
        } catch {
            NSLog("Notification diagnostics could not be saved: %@", error.localizedDescription)
        }
    }

    // 保留旧调用入口；无论历史设置或同步数据是什么，都不会重新申请通知权限。
    static func requestPermission(_ then: @escaping () -> Void = {}) {
        cancelAll()
        then()
    }

    @MainActor
    static func reschedule(_: Store) {
        cancelAll()
    }
}
