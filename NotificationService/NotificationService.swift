import Foundation
import CryptoKit
import UserNotifications

/// APNs carries only the AES-GCM ciphertext. This extension decrypts it on the
/// partner's iPhone and prepares local reminders without exposing dose details
/// to Cloudflare or Apple Push Notification service.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content
        Task {
            await prepare(content, userInfo: request.content.userInfo)
            contentHandler(content)
            self.contentHandler = nil
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private func prepare(_ content: UNMutableNotificationContent,
                         userInfo: [AnyHashable: Any]) async {
        content.title = "药时共享更新"
        content.body = "你先生的共享记录有更新。打开药时查看。"
        content.sound = .default

        let loadedCredentials: PartnerSpaceCredentials?
        do {
            loadedCredentials = try PartnerCredentialVault.load(app: .yaoShi)
        } catch {
            return
        }
        guard PartnerBuildConfiguration.role == .partner,
              let ciphertextText = userInfo["ciphertext"] as? String,
              let ciphertext = Data(base64Encoded: ciphertextText),
              let credentials = loadedCredentials, credentials.role == .partner,
              let box = try? AES.GCM.SealedBox(combined: ciphertext),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: credentials.encryptionKey)),
              let message = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return
        }

        guard message["kind"] as? String == "dose",
              message["notifyPartner"] as? Bool == true,
              let medication = message["medication"] as? String,
              let milligrams = message["milligrams"] as? Int,
              let occurredAtSeconds = message["occurredAt"] as? Double else {
            return
        }

        let occurredAt = Date(timeIntervalSinceReferenceDate: occurredAtSeconds)
        let roundGapHours = min(max(message["roundGapHours"] as? Int ?? 48, 1), 720)
        let previousDoseAt = (message["previousDoseAt"] as? Double)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        let intervalText: String
        if let previousDoseAt {
            let elapsed = max(0, occurredAt.timeIntervalSince(previousDoseAt))
            intervalText = elapsed > TimeInterval(roundGapHours) * 3600
                ? "距上一条记录约 \(elapsedText(elapsed))，超过 \(roundGapHours) 小时分波间隔，按记录规则进入新一波"
                : "距上一条记录约 \(elapsedText(elapsed))，仍在同一波记录中"
        } else {
            intervalText = "这是目前同步记录中的第一条服药记录"
        }

        content.title = "你先生记录了服药"
        content.body = "\(medication) \(milligrams) 毫克；记录时间：\(occurredAt.formatted(date: .abbreviated, time: .shortened))。\(intervalText)。"
        content.userInfo["occurredAt"] = occurredAt.timeIntervalSince1970
        content.userInfo["roundGapHours"] = roundGapHours
        await scheduleStatusNotifications(lastDoseAt: occurredAt, gapHours: roundGapHours)
    }

    private func scheduleStatusNotifications(lastDoseAt: Date, gapHours: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix("yaoshi-status-") }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)

        let endedAt = lastDoseAt.addingTimeInterval(TimeInterval(gapHours) * 3600)
        let now = Date()
        if endedAt > now {
            let content = statusContent(
                title: "这一波服药记录已结束",
                body: "距最近一条共享服药记录已达到设定的 \(gapHours) 小时分波间隔；按记录规则，这一波到此结束。",
                lastDoseAt: lastDoseAt
            )
            await add(content, identifier: "yaoshi-status-wave-\(Int(lastDoseAt.timeIntervalSince1970))", at: endedAt, center: center)
        }

        let day: TimeInterval = 24 * 3600
        let elapsedDays = max(1, Int(floor(now.timeIntervalSince(endedAt) / day)) + 1)
        for index in 0..<50 {
            let dayNumber = elapsedDays + index
            let fireAt = endedAt.addingTimeInterval(TimeInterval(dayNumber) * day)
            let elapsed = max(TimeInterval(gapHours) * 3600, fireAt.timeIntervalSince(lastDoseAt))
            let content = statusContent(
                title: "服药记录状态",
                body: "又过了一天，尚未收到新的共享服药记录；距最近一条约 \(elapsedText(elapsed))（\(lastDoseAt.formatted(date: .abbreviated, time: .shortened))）。这里只反映已同步记录。",
                lastDoseAt: lastDoseAt
            )
            await add(content, identifier: "yaoshi-status-day-\(dayNumber)-\(Int(lastDoseAt.timeIntervalSince1970))", at: fireAt, center: center)
        }
    }

    private func statusContent(title: String, body: String, lastDoseAt: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["lastDoseAt": lastDoseAt.timeIntervalSince1970]
        return content
    }

    private func elapsedText(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainder = minutes % 60
        if days > 0 {
            return remainder > 0 ? "\(days) 天 \(hours) 小时 \(remainder) 分钟" : "\(days) 天 \(hours) 小时"
        }
        if hours > 0 { return remainder > 0 ? "\(hours) 小时 \(remainder) 分钟" : "\(hours) 小时" }
        return "\(minutes) 分钟"
    }

    private func add(_ content: UNNotificationContent, identifier: String,
                     at date: Date, center: UNUserNotificationCenter) async {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }
}
