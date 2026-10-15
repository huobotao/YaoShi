import Foundation
import Combine
import WatchConnectivity

@MainActor
final class PhoneWatchLink: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchLink()
    private weak var store: Store?
    private var observation: AnyCancellable?
    private var publishScheduled = false
    private var lastDeliveryError: String?
    private var lastEventError: String?
    private var lastSnapshotSentAt: Date?

    private func writeDiagnostics() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let report: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "activationState": session.activationState.rawValue,
            "isPaired": session.isPaired,
            "isWatchAppInstalled": session.isWatchAppInstalled,
            "isReachable": session.isReachable,
            "phoneRecordCount": store?.doses.count ?? 0,
            "phoneNoteCount": store?.effects.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count ?? 0,
            "snapshotRecordCount": snapshot()?.recentDoses.count ?? 0,
            "lastSnapshotSentAt": lastSnapshotSentAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "lastError": lastEventError ?? lastDeliveryError ?? ""
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? bytes.write(to: documents.appendingPathComponent("watchdiagnostics.json"), options: .atomic)
    }

    func start(store: Store) {
        guard self.store !== store else { return }
        self.store = store
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.scheduleSnapshot() }
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        publishSnapshot()
    }

    private func scheduleSnapshot() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.publishSnapshot()
        }
    }

    private func snapshot() -> WatchPhoneSnapshot? {
        guard let store else { return nil }
        let now = Date()
        let records = store.doses.filter { $0.at <= now }.sorted { $0.at > $1.at }
        func summary(_ dose: Dose) -> WatchDoseSummary { .init(id: dose.id, at: dose.at, mg: dose.mg, med: dose.med) }
        let notes = store.effects.filter {
            $0.at <= now && $0.at >= now.addingTimeInterval(-7 * 86400)
            && !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.at > $1.at }.prefix(12).map { log -> WatchNoteSummary in
            var preview = String(log.note.prefix(WatchNoteEvent.maxCharacters))
            while preview.utf8.count > WatchNoteEvent.maxUTF8Bytes { preview.removeLast() }
            if preview != log.note { preview = String(preview.dropLast()) + "…" }
            return .init(id: log.id, at: log.at, note: preview)
        }
        var result = WatchPhoneSnapshot(generatedAt: now, defaultMg: store.settings.defaultMg,
                                       latestDose: records.first.map(summary),
                                       recentDoses: records.filter { $0.at >= now.addingTimeInterval(-7 * 86400) }.prefix(100).map(summary),
                                       recentNotes: notes, supportsNotes: true)
        if !records.isEmpty {
            let model = DoseCurveModel(doses: store.doses, now: now, curve: store.settings.plasmaCurve)
            let keyDates = model.visibleDoses.suffix(100).flatMap { dose in
                [dose.at,
                 dose.at.addingTimeInterval(model.curve.lag(for: dose.food) * 3600),
                 dose.at.addingTimeInterval(model.curve.peakTimeHours * 3600)]
            }
            let samples = WatchCurveSampling.samples(start: model.start, end: model.end,
                now: now, keyDates: keyDates, levelAt: model.level(at:))
            result.curve = WatchCurveSnapshot(start: model.start, end: model.end, now: now,
                currentLevel: model.currentLevel, upperLevel: model.upperLevel,
                samples: samples,
                doses: model.visibleDoses.suffix(100).map { WatchCurveSample(at: $0.at, level: model.level(at: $0.at)) })
        }
        // Leave room for the reply envelope and ACK. Bound escaped JSON bytes as well as text length.
        while (try? JSONEncoder().encode(result).count).map({ $0 > 56 * 1024 }) ?? true {
            if result.recentDoses.count > 1 { result.recentDoses.removeLast() }
            else if !(result.recentNotes ?? []).isEmpty { result.recentNotes?.removeLast() }
            else { return nil }
        }
        return result
    }

    func publishSnapshot() {
        defer { writeDiagnostics() }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let data = YaoShiWatchWire.encode(WatchPhoneReply(snapshot: snapshot())) else { return }
        do {
            try WCSession.default.updateApplicationContext([YaoShiWatchWire.key: data])
            lastSnapshotSentAt = Date()
            lastDeliveryError = nil
        } catch { lastDeliveryError = error.localizedDescription }
    }

    private func receive(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let request = YaoShiWatchWire.decode(WatchPhoneRequest.self, from: message), request.version == 1 else {
            replyHandler?([:]); return
        }
        var result = WatchPhoneReply()
        if request.event != nil && request.noteEvent != nil {
            result.error = "记录类型不明确，已保留在手表。请更新药时后重试。"
        } else if let event = request.event {
            if !event.isValid() { result.error = "记录未通过校验，请检查手表时间并在手机核对。" }
            else if let store, store.acceptWatchDose(id: event.id, at: event.at, mg: event.mg,
                                                    med: event.med, recordedAt: event.recordedAt) {
                result.acknowledgedIDs = [event.id]
            } else { result.error = "手机尚未保存成功，记录仍保留在手表，稍后重试。" }
        } else if let event = request.noteEvent {
            if !event.isValid() { result.error = "笔记未通过校验，请检查文字长度与手表时间。" }
            else if let store, store.acceptWatchNote(id: event.id, at: event.at, note: event.note, recordedAt: event.recordedAt) {
                result.acknowledgedNoteIDs = [event.id]
            } else { result.error = "手机尚未保存成功，笔记仍保留在手表，稍后重试。" }
        }
        if request.event != nil || request.noteEvent != nil { lastEventError = result.error }
        result.snapshot = snapshot()
        guard let bytes = YaoShiWatchWire.encode(result) else { replyHandler?([:]); return }
        let output: [String: Any] = [YaoShiWatchWire.key: bytes]
        if let replyHandler { replyHandler(output) }
        else if WCSession.default.activationState == .activated {
            // Background receipt has no reply callback. Queue its durable ACK to the Watch.
            let hasAcknowledgement = !result.acknowledgedIDs.isEmpty || !(result.acknowledgedNoteIDs ?? []).isEmpty
            let alreadyQueued = hasAcknowledgement && WCSession.default.outstandingUserInfoTransfers.contains {
                let queued = YaoShiWatchWire.decode(WatchPhoneReply.self, from: $0.userInfo)
                return queued?.acknowledgedIDs == result.acknowledgedIDs
                    && queued?.acknowledgedNoteIDs == result.acknowledgedNoteIDs
            }
            if !alreadyQueued { WCSession.default.transferUserInfo(output) }
            if WCSession.default.isReachable { WCSession.default.sendMessage(output, replyHandler: nil, errorHandler: { _ in }) }
        }
        publishSnapshot()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { self.lastDeliveryError = error.localizedDescription }
            if activationState == .activated { self.publishSnapshot() }
            else { self.writeDiagnostics() }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.writeDiagnostics() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishSnapshot() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.receive(message, replyHandler: replyHandler) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message, replyHandler: nil) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.receive(userInfo, replyHandler: nil) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
