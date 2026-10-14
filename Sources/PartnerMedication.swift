import Foundation
import Combine
import SwiftUI
import CryptoKit
import UserNotifications

enum MedicationShareKind: String, Codable {
    case dose
    case removal
    case comment
}

/// Deliberately excludes reasons, personal notes, sleep, food events, settings,
/// inventory and any model estimates. Only the selected event is serialized.
struct MedicationShareMessage: Codable, Identifiable {
    var id: UUID
    var kind: MedicationShareKind
    var doseID: UUID
    var updatedAt: Date
    var medication: String? = nil
    var milligrams: Int? = nil
    var occurredAt: Date? = nil
    /// Included only in the encrypted event so the partner's device can describe
    /// the interval without exposing dose times to the relay or APNs payload.
    var previousDoseAt: Date? = nil
    var food: FoodState? = nil
    var notifyPartner: Bool? = nil
    var roundGapHours: Int? = nil
    var text: String? = nil
    var replyTo: UUID? = nil

    static func dose(_ dose: Dose, notifyPartner: Bool = false,
                     roundGapHours: Int = 48,
                     previousDoseAt: Date? = nil) -> MedicationShareMessage {
        MedicationShareMessage(id: DoseEventIdentity.id(for: dose), kind: .dose, doseID: dose.id,
                               updatedAt: dose.updatedAt ?? Date(), medication: dose.med,
                               milligrams: dose.mg, occurredAt: dose.at,
                               previousDoseAt: previousDoseAt, food: dose.food,
                               notifyPartner: notifyPartner, roundGapHours: roundGapHours)
    }

    static func removal(doseID: UUID, eventID: UUID = UUID()) -> MedicationShareMessage {
        MedicationShareMessage(id: eventID, kind: .removal, doseID: doseID, updatedAt: Date())
    }

    static func comment(doseID: UUID, text: String, replyTo: UUID? = nil,
                        eventID: UUID = UUID()) -> MedicationShareMessage {
        MedicationShareMessage(id: eventID, kind: .comment, doseID: doseID, updatedAt: Date(),
                               text: text, replyTo: replyTo)
    }
}

private enum DoseEventIdentity {
    static func id(for dose: Dose) -> UUID {
        let revision = dose.updatedAt?.timeIntervalSince1970.bitPattern ?? dose.at.timeIntervalSince1970.bitPattern
        let digest = SHA256.hash(data: Data("\(dose.id.uuidString):\(revision)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? dose.id
    }
}

struct SharedMedicationDose: Codable, Identifiable, Hashable {
    var id: UUID
    var medication: String
    var milligrams: Int
    var occurredAt: Date
    var food: FoodState
    var updatedAt: Date
    var roundGapHours: Int?
}

struct SharedMedicationComment: Codable, Identifiable, Hashable {
    var id: UUID
    var doseID: UUID
    var author: PartnerRole
    var text: String
    var createdAt: Date
    var replyTo: UUID?
}

private struct MedicationShareSnapshot: Codable {
    var sharedDoseIDs: Set<UUID> = []
    var doses: [SharedMedicationDose] = []
    var removals: [UUID: Date] = [:]
    var comments: [SharedMedicationComment] = []
    var processedEventIDs: Set<UUID> = []
    var pendingMessages: [MedicationShareMessage] = []
}

@MainActor
final class MedicationShareRepository: ObservableObject {
    static let shared = MedicationShareRepository()

    @Published private(set) var sharedDoseIDs: Set<UUID> = []
    @Published private(set) var doses: [SharedMedicationDose] = []
    @Published private(set) var comments: [SharedMedicationComment] = []
    @Published private(set) var status = "共享记录保存在本机"

    private var snapshot = MedicationShareSnapshot()
    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("partner-medication-share.json")
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private init() {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(MedicationShareSnapshot.self, from: data) else { return }
        snapshot = value
        publishSnapshot()
    }

    func isShared(_ doseID: UUID) -> Bool { snapshot.sharedDoseIDs.contains(doseID) }

    func comments(for doseID: UUID) -> [SharedMedicationComment] {
        snapshot.comments.filter { $0.doseID == doseID }.sorted { $0.createdAt < $1.createdAt }
    }

    func setShared(_ dose: Dose, enabled: Bool) {
        let previous = snapshot
        let message: MedicationShareMessage
        if enabled {
            snapshot.sharedDoseIDs.insert(dose.id)
            var sharedDose = dose
            sharedDose.updatedAt = Date()
            upsertLocal(sharedDose)
            message = .dose(sharedDose)
            status = "已选择分享这条服药记录"
        } else {
            snapshot.sharedDoseIDs.remove(dose.id)
            snapshot.doses.removeAll { $0.id == dose.id }
            snapshot.removals[dose.id] = Date()
            message = .removal(doseID: dose.id)
            status = "已停止分享这条服药记录"
        }
        guard enqueue(message) else { snapshot = previous; publishSnapshot(); return }
        publishSnapshot()
    }

    /// New, durably saved dose records are shared automatically once the owner
    /// has established the YaoShi space. Historical records are not backfilled.
    func publishNewDose(_ dose: Dose, roundGapHours: Int = 48, previousDoseAt: Date? = nil) {
        guard PartnerBuildConfiguration.role == .owner,
              PartnerSharingCoordinator.shared.credentials[.yaoShi]?.role == .owner else { return }
        let previous = snapshot
        snapshot.sharedDoseIDs.insert(dose.id)
        upsertLocal(dose, roundGapHours: roundGapHours)
        guard enqueue(.dose(dose, notifyPartner: true, roundGapHours: roundGapHours,
                            previousDoseAt: previousDoseAt)) else {
            snapshot = previous; publishSnapshot(); return
        }
        publishSnapshot()
    }

    func publishIfShared(_ dose: Dose, roundGapHours: Int = 48) {
        guard snapshot.sharedDoseIDs.contains(dose.id) else { return }
        let previous = snapshot
        upsertLocal(dose, roundGapHours: roundGapHours)
        guard enqueue(.dose(dose, roundGapHours: roundGapHours)) else { snapshot = previous; publishSnapshot(); return }
        publishSnapshot()
    }

    func removeIfShared(_ doseID: UUID) {
        guard snapshot.sharedDoseIDs.contains(doseID) else { return }
        let previous = snapshot
        snapshot.sharedDoseIDs.remove(doseID)
        snapshot.doses.removeAll { $0.id == doseID }
        snapshot.removals[doseID] = Date()
        guard enqueue(.removal(doseID: doseID)) else { snapshot = previous; publishSnapshot(); return }
        publishSnapshot()
    }

    @discardableResult
    func addComment(doseID: UUID, text: String, replyTo: UUID? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000,
              snapshot.doses.contains(where: { $0.id == doseID }),
              replyTo.map({ replyID in
                  snapshot.comments.contains { $0.id == replyID && $0.doseID == doseID }
              }) ?? true else { return false }
        let message = MedicationShareMessage.comment(doseID: doseID, text: trimmed, replyTo: replyTo)
        let previous = snapshot
        snapshot.comments.append(SharedMedicationComment(id: message.id, doseID: doseID,
                                                         author: PartnerBuildConfiguration.role,
                                                         text: trimmed, createdAt: message.updatedAt,
                                                         replyTo: replyTo))
        guard enqueue(message) else { snapshot = previous; publishSnapshot(); return false }
        publishSnapshot()
        return true
    }

    func sync() async {
        guard PartnerApp.current == .yaoShi else { return }
        let coordinator = PartnerSharingCoordinator.shared
        await flushPendingMessages()
        await coordinator.sync(app: .yaoShi)
        guard var journal = coordinator.journals[.yaoShi] else { return }
        for event in journal.incoming.sorted(by: { $0.revision < $1.revision }) {
            if LocationBatch.matchesPayload(event.payload) {
                guard let active = coordinator.credentials[.yaoShi],
                      event.sourceSharingIdentity == active.locationSharingIdentity else {
                    // A decrypted event retained from a previous space must never
                    // appear as the new partner's current position.
                    coordinator.acknowledgeReceived(app: .yaoShi, eventID: event.id)
                    continue
                }
                if let batch = try? JSONDecoder().decode(LocationBatch.self, from: event.payload),
                   LocationSharingManager.shared.receive(batch, author: event.author.rawValue, receivedAt: Date()) {
                    coordinator.acknowledgeReceived(app: .yaoShi, eventID: event.id)
                } else {
                    status = "位置记录无法验证或保存；原数据仍保留"
                }
                continue
            }
            if snapshot.processedEventIDs.contains(event.id) {
                coordinator.acknowledgeReceived(app: .yaoShi, eventID: event.id)
                continue
            }
            guard let message = try? JSONDecoder().decode(MedicationShareMessage.self, from: event.payload) else {
                status = "收到无法识别的共享记录；原数据仍保留"
                continue
            }
            apply(message, author: event.author)
            snapshot.processedEventIDs.insert(event.id)
            guard save() else {
                snapshot.processedEventIDs.remove(event.id)
                status = "共享记录已读取，但本机保存失败；稍后会重试"
                continue
            }
            coordinator.acknowledgeReceived(app: .yaoShi, eventID: event.id)
            if PartnerBuildConfiguration.role == .partner,
               event.author == .owner, event.notifyPartner == true,
               message.kind == .dose, message.notifyPartner == true,
               let occurredAt = message.occurredAt {
                await PartnerMedicationNotificationPlanner.shared.didReceiveDose(
                    eventID: message.id,
                    medication: message.medication ?? "服药",
                    milligrams: message.milligrams ?? 0,
                    occurredAt: occurredAt,
                    previousDoseAt: message.previousDoseAt,
                    roundGapHours: message.roundGapHours ?? 48
                )
            }
            if PartnerBuildConfiguration.role == .partner,
               event.author == .owner, (message.kind == .dose || message.kind == .removal) {
                await PartnerMedicationNotificationPlanner.shared.refreshStatusNotifications(doses: snapshot.doses)
            }
            journal.incoming.removeAll { $0.id == event.id }
        }
        publishSnapshot()
    }

    private func apply(_ message: MedicationShareMessage, author: PartnerRole) {
        switch message.kind {
        case .dose:
            guard author == .owner, let medicine = message.medication,
                  let mg = message.milligrams, mg > 0, let at = message.occurredAt,
                  let food = message.food,
                  (snapshot.removals[message.doseID] ?? .distantPast) < message.updatedAt else { return }
            let dose = SharedMedicationDose(id: message.doseID, medication: medicine,
                                            milligrams: mg, occurredAt: at, food: food,
                                            updatedAt: message.updatedAt,
                                            roundGapHours: message.roundGapHours)
            snapshot.doses.removeAll { $0.id == dose.id }
            snapshot.doses.append(dose)
            snapshot.doses.sort { $0.occurredAt > $1.occurredAt }
        case .removal:
            guard author == .owner else { return }
            snapshot.removals[message.doseID] = max(snapshot.removals[message.doseID] ?? .distantPast,
                                                     message.updatedAt)
            snapshot.doses.removeAll { $0.id == message.doseID }
            snapshot.sharedDoseIDs.remove(message.doseID)
        case .comment:
            guard let text = message.text, !text.isEmpty, text.count <= 1000,
                  !snapshot.comments.contains(where: { $0.id == message.id }) else { return }
            snapshot.comments.append(SharedMedicationComment(id: message.id, doseID: message.doseID,
                                                             author: author, text: text,
                                                             createdAt: message.updatedAt,
                                                             replyTo: message.replyTo))
        }
    }

    private func upsertLocal(_ dose: Dose, roundGapHours: Int? = nil) {
        let value = SharedMedicationDose(id: dose.id, medication: dose.med, milligrams: dose.mg,
                                         occurredAt: dose.at, food: dose.food,
                                         updatedAt: dose.updatedAt ?? Date(),
                                         roundGapHours: roundGapHours)
        snapshot.doses.removeAll { $0.id == value.id }
        snapshot.doses.append(value)
        snapshot.doses.sort { $0.occurredAt > $1.occurredAt }
        snapshot.removals.removeValue(forKey: value.id)
    }

    @discardableResult
    private func enqueue(_ message: MedicationShareMessage) -> Bool {
        snapshot.pendingMessages.append(message)
        guard save() else {
            snapshot.pendingMessages.removeAll { $0.id == message.id }
            return false
        }
        Task { await flushPendingMessages() }
        return true
    }

    private func flushPendingMessages() async {
        guard PartnerApp.current == .yaoShi else { return }
        let coordinator = PartnerSharingCoordinator.shared
        for message in snapshot.pendingMessages {
            guard let payload = try? encoder.encode(message),
                  await coordinator.enqueue(app: .yaoShi, eventID: message.id, payload: payload,
                                            notifyPartner: message.kind == .dose && message.notifyPartner == true) else { return }
            let previous = snapshot
            snapshot.pendingMessages.removeAll { $0.id == message.id }
            guard save() else { snapshot = previous; publishSnapshot(); return }
        }
    }

    private func save() -> Bool {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            publishSnapshot()
            return true
        } catch {
            status = "共享记录本机保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func publishSnapshot() {
        sharedDoseIDs = snapshot.sharedDoseIDs
        doses = snapshot.doses.sorted { $0.occurredAt > $1.occurredAt }
        comments = snapshot.comments.sorted { $0.createdAt < $1.createdAt }
    }
}

@MainActor
final class PartnerMedicationNotificationPlanner {
    static let shared = PartnerMedicationNotificationPlanner()
    private let center = UNUserNotificationCenter.current()
    private let statusPrefix = "yaoshi-status-"
    private let dosePrefix = "yaoshi-dose-"

    private init() {}

    func didReceiveDose(eventID: UUID, medication: String, milligrams: Int, occurredAt: Date,
                        previousDoseAt: Date?, roundGapHours: Int) async {
        guard await ensurePermission() else { return }
        let timeText = occurredAt.formatted(date: .abbreviated, time: .shortened)
        let detail: String
        if let previousDoseAt {
            let elapsed = max(0, occurredAt.timeIntervalSince(previousDoseAt))
            detail = elapsed > TimeInterval(roundGapHours) * 3600
                ? "距上一条已同步记录约 \(medicationElapsedText(elapsed))，超过 \(roundGapHours) 小时分波间隔，按记录规则进入新一波"
                : "距上一条已同步记录约 \(medicationElapsedText(elapsed))，仍在同一波记录中"
        } else {
            detail = "目前同步记录中的第一条服药记录"
        }
        let content = UNMutableNotificationContent()
        content.title = "你先生记录了服药"
        content.body = "\(medication) \(milligrams) 毫克；记录时间：\(timeText)。\(detail)。"
        content.sound = .default
        content.userInfo = ["eventID": eventID.uuidString, "medication": medication,
                            "occurredAt": occurredAt.timeIntervalSince1970,
                            "roundGapHours": roundGapHours]
        if !UserDefaults.standard.bool(forKey: "yaoshi.partner.pushRegistered") {
            schedule(content, identifier: "\(dosePrefix)\(eventID.uuidString)", at: Date().addingTimeInterval(1))
        }
    }

    func refreshStatusNotifications(doses: [SharedMedicationDose], now: Date = Date()) async {
        guard PartnerBuildConfiguration.role == .partner else { return }
        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix(statusPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        guard let last = doses.max(by: { $0.occurredAt < $1.occurredAt }) else { return }
        guard await ensurePermission() else { return }

        let gapHours = min(max(last.roundGapHours ?? 48, 1), 720)
        let endedAt = last.occurredAt.addingTimeInterval(TimeInterval(gapHours) * 3600)
        if endedAt > now {
            let content = UNMutableNotificationContent()
            content.title = "这一波服药记录已结束"
            content.body = "距最近一条共享服药记录已达到设定的 \(gapHours) 小时分波间隔；按记录规则，这一波到此结束。"
            content.sound = .default
            content.userInfo = ["lastDoseAt": last.occurredAt.timeIntervalSince1970]
            schedule(content, identifier: "\(statusPrefix)wave-\(last.id)", at: endedAt)
        }

        let day = TimeInterval(24 * 3600)
        // The wave-end alert already covers the boundary; start daily status updates
        // one full day later and leave room under iOS's pending-notification cap.
        let elapsedDays = max(1, Int(floor(now.timeIntervalSince(endedAt) / day)) + 1)
        for index in 0..<50 {
            let daysSinceWaveEnd = elapsedDays + index
            let fireAt = endedAt.addingTimeInterval(TimeInterval(daysSinceWaveEnd) * day)
            guard fireAt > now else { continue }
            let elapsed = max(TimeInterval(gapHours) * 3600, fireAt.timeIntervalSince(last.occurredAt))
            let content = UNMutableNotificationContent()
            content.title = "服药记录状态"
            content.body = "又过了一天，尚未收到新的共享服药记录；距最近一条约 \(medicationElapsedText(elapsed))（\(last.occurredAt.formatted(date: .abbreviated, time: .shortened))）。这里只反映已同步记录。"
            content.sound = .default
            content.userInfo = ["lastDoseAt": last.occurredAt.timeIntervalSince1970]
            schedule(content, identifier: "\(statusPrefix)day-\(daysSinceWaveEnd)-\(last.id)", at: fireAt)
        }
    }

    private func ensurePermission() async -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        guard settings.authorizationStatus == .notDetermined else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func schedule(_ content: UNMutableNotificationContent, identifier: String, at date: Date) {
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(
                                                timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
        center.add(request)
    }
}

private func medicationElapsedText(_ interval: TimeInterval) -> String {
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

struct YaoShiPartnerView: View {
    @ObservedObject private var repository = MedicationShareRepository.shared
    @ObservedObject private var sharing = PartnerSharingCoordinator.shared
    @State private var commentingOn: SharedMedicationDose?
    @State private var draft = ""
    @State private var replyTo: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PartnerSharingControls(app: .yaoShi)
                } header: {
                    Text("共享状态")
                }

                Section {
                    NavigationLink("位置共享") { LocationSharingView() }
                }

                Section("已分享的服药记录") {
                    if repository.doses.isEmpty {
                        Text("目前还没有收到分享记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(repository.doses) { dose in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(dose.medication).font(.headline)
                                    Spacer()
                                    Text("\(dose.milligrams) 毫克").font(.subheadline)
                                }
                                Text(dose.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(dose.food.label).font(.caption).foregroundStyle(.secondary)
                                Button("讨论这条记录（\(repository.comments(for: dose.id).count)）") {
                                    commentingOn = dose
                                    draft = ""
                                    replyTo = nil
                                }
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let latest = repository.doses.max(by: { $0.occurredAt < $1.occurredAt }) {
                    Section("当前记录状态") {
                        Text("距最近一条已同步记录 \(elapsedText(since: latest.occurredAt, now: Date()))")
                        Text("最近记录：\(latest.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if Date().timeIntervalSince(latest.occurredAt) > TimeInterval(latest.roundGapHours ?? 48) * 3600 {
                            Text("按 \(latest.roundGapHours ?? 48) 小时的分波间隔，这一波记录已结束。此说明只按记录间隔计算，不代表药效或药物已代谢完毕。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

            }
            .navigationTitle("药时共享")
            .task { await repository.sync() }
            .onChange(of: sharing.journals[.yaoShi]) { _, _ in
                Task { await repository.sync() }
            }
            .sheet(item: $commentingOn) { dose in
                NavigationStack {
                    medicationCommentThread(dose: dose, repository: repository,
                                            draft: $draft, replyTo: $replyTo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { commentingOn = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { commentingOn = nil }
                        }
                    }
                }
            }
        }
    }
}

private func elapsedText(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days) 天 \(hours) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
    return "\(minutes) 分钟"
}

@MainActor
private func medicationCommentThread(
    dose: SharedMedicationDose,
    repository: MedicationShareRepository,
    draft: Binding<String>,
    replyTo: Binding<UUID?>
) -> some View {
    List {
        Section("服药记录") {
            Text("\(dose.medication) · \(dose.milligrams) 毫克 · \(dose.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
        }
        Section("讨论") {
            if repository.comments(for: dose.id).isEmpty {
                Text("还没有评论；这里写下的内容会与这条记录一起共享。")
                    .foregroundStyle(.secondary)
            }
            ForEach(repository.comments(for: dose.id)) { comment in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(medicationCommentAuthorLabel(comment.author, current: PartnerBuildConfiguration.role))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let replyTo = comment.replyTo,
                       let parent = repository.comments(for: dose.id).first(where: { $0.id == replyTo }) {
                        Text("回复：\(parent.text)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(comment.text)
                    Button("回复") { replyTo.wrappedValue = comment.id }
                        .font(.caption)
                }
                .padding(.vertical, 3)
            }
        }
        Section(replyTo.wrappedValue == nil ? "发表评论或感受" : "回复评论") {
            if replyTo.wrappedValue != nil {
                Button("取消回复") { replyTo.wrappedValue = nil }
                    .font(.caption)
            }
            TextField("写下评论或此刻感受", text: draft, axis: .vertical).lineLimit(3...8)
            Button("发送到共享讨论") {
                if repository.addComment(doseID: dose.id, text: draft.wrappedValue,
                                         replyTo: replyTo.wrappedValue) {
                    draft.wrappedValue = ""
                    replyTo.wrappedValue = nil
                }
            }
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    .navigationTitle("服药记录讨论")
    .navigationBarTitleDisplayMode(.inline)
}

private func medicationCommentAuthorLabel(_ author: PartnerRole, current: PartnerRole) -> String {
    if author == current { return "你" }
    return author == .owner ? "先生" : "太太"
}

#if !YAOSHI_PARTNER
struct YaoShiOwnerSharingView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var repository = MedicationShareRepository.shared
    @State private var commentingOn: SharedMedicationDose?
    @State private var draft = ""
    @State private var replyTo: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PartnerSharingControls(app: .yaoShi)
                } header: {
                    Text("跨 Apple ID 连接")
                }

                Section("自动共享新记录") {
                    Label("连接伴侣后，每条新服药记录都会自动共享", systemImage: "arrow.triangle.2.circlepath.icloud")
                    Text("只发送药名、剂量、实际服药时间和随餐状态。既有历史记录不会自动补发；原因、感受笔记、睡眠和其他私人资料不会发送。只有写进共享讨论串的评论或感受会传给太太。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.doses.isEmpty {
                        Text("还没有服药记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(repository.doses) { dose in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(dose.medication) · \(dose.milligrams) 毫克")
                                Text(dose.occurredAt.formatted(date: .abbreviated, time: .shortened) + " · " + dose.food.label)
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("添加回应或感受（\(repository.comments(for: dose.id).count)）") {
                                    commentingOn = dose
                                    draft = ""
                                    replyTo = nil
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .navigationTitle("伴侣共享")
            .task { await repository.sync() }
            .sheet(item: $commentingOn) { dose in
                NavigationStack {
                    medicationCommentThread(dose: dose, repository: repository,
                                            draft: $draft, replyTo: $replyTo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { commentingOn = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { commentingOn = nil }
                        }
                    }
                }
            }
        }
        .onChange(of: store.doses) { _, new in
            for dose in new {
                repository.publishIfShared(dose, roundGapHours: store.settings.newRoundGapHours)
            }
        }
    }
}
#endif
