import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit

@MainActor
final class YaoShiWatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = YaoShiWatchLink()
    @Published private(set) var state = WatchLocalState()
    @Published private(set) var storageReady = false
    @Published private(set) var issue: String?
    @Published private(set) var reachable = false
    private var journal: WatchJournal?
    private var timer: Timer?
    private var lastInstantSend: [String: Date] = [:]
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var contentObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let file = directory.appendingPathComponent("YaoShi/watch-journal-v1.json")
            let journal = try WatchJournal(fileURL: file)
            self.journal = journal
            state = journal.state
            storageReady = true
        } catch { issue = "无法读取手表记录，已暂停新增。请保留 App 并在手机核对。" }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        contentObservation = WCSession.default.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.finishBackgroundTasks() }
        }
        WCSession.default.activate()
    }

    private func commit(_ next: WatchLocalState) -> Bool {
        guard storageReady, let journal else { return false }
        do {
            try journal.commit(next)
            state = next
            return true
        } catch {
            storageReady = false
            issue = "手表保存失败，已暂停新增。请重新打开 App 核对记录。"
            return false
        }
    }

    @discardableResult
    func record(id: UUID, mg: Int, med: String) -> Bool {
        guard storageReady, state.snapshot?.allowsRecording == true, state.pending.count < 100 else { return false }
        let now = Date()
        let event = WatchDoseEvent(id: id, at: now, mg: mg, med: med, recordedAt: now)
        guard event.isValid() else { return false }
        var next = state
        next.enqueue(event)
        guard commit(next) else { return false }
        issue = nil
        WKInterfaceDevice.current().play(.success)
        flush()
        return true
    }

    @discardableResult
    func recordNote(id: UUID, at: Date, note: String) -> Bool {
        guard storageReady, state.pendingNotes.count < 100 else { return false }
        let event = WatchNoteEvent(id: id, at: at, note: note.trimmingCharacters(in: .whitespacesAndNewlines), recordedAt: Date())
        guard event.isValid() else { return false }
        var next = state
        next.enqueue(event)
        guard commit(next) else { return false }
        issue = nil
        WKInterfaceDevice.current().play(.success)
        flush()
        return true
    }

    func setActive(_ active: Bool) {
        timer?.invalidate(); timer = nil
        if active {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        reachable = session.isReachable
        receive(session.receivedApplicationContext)
        flush()
        guard session.isReachable, let data = YaoShiWatchWire.encode(WatchPhoneRequest()) else { return }
        session.sendMessage([YaoShiWatchWire.key: data], replyHandler: { message in
            Task { @MainActor in self.receive(message) }
        }, errorHandler: { _ in })
    }

    private func flush() {
        guard storageReady, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        reachable = session.isReachable
        let queuedKeys = Set(session.outstandingUserInfoTransfers.compactMap {
            YaoShiWatchWire.decode(WatchPhoneRequest.self, from: $0.userInfo)?.deliveryKey
        })
        let requests = state.pending.map { WatchPhoneRequest(event: $0) }
            + state.pendingNotes.map { WatchPhoneRequest(noteEvent: $0) }
        for request in requests {
            guard let key = request.deliveryKey, let bytes = YaoShiWatchWire.encode(request) else { continue }
            let payload: [String: Any] = [YaoShiWatchWire.key: bytes]
            if !queuedKeys.contains(key) { session.transferUserInfo(payload) }
            if session.isReachable, lastInstantSend[key].map({ Date().timeIntervalSince($0) >= 10 }) ?? true {
                lastInstantSend[key] = Date()
                session.sendMessage(payload, replyHandler: { message in
                    Task { @MainActor in self.receive(message) }
                }, errorHandler: { _ in }) // Keep durable outbox; the next foreground retry uses the same UUID.
            }
        }
    }

    private func receive(_ message: [String: Any]) {
        guard let reply = YaoShiWatchWire.decode(WatchPhoneReply.self, from: message), reply.version == 1 else { return }
        var next = state
        next.absorb(reply)
        guard next == state || commit(next) else { return }
        if let error = reply.error { issue = error }
        else if storageReady { issue = nil }
        // A confirmed event no longer needs an outstanding background transport copy.
        let acknowledged = Set(reply.acknowledgedIDs.map { "dose:" + $0.uuidString }
                               + (reply.acknowledgedNoteIDs ?? []).map { "note:" + $0.uuidString })
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            if let key = YaoShiWatchWire.decode(WatchPhoneRequest.self, from: transfer.userInfo)?.deliveryKey,
               acknowledged.contains(key) { transfer.cancel() }
        }
        for key in acknowledged { lastInstantSend.removeValue(forKey: key) }
    }

    func retainBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task else { return }
                self.backgroundTasks.removeAll { $0 === task }
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        finishBackgroundTasks()
    }
    private func finishBackgroundTasks() {
        guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
        receive(WCSession.default.receivedApplicationContext)
        let completed = backgroundTasks
        backgroundTasks.removeAll()
        for task in completed { task.expirationHandler = nil; task.setTaskCompletedWithSnapshot(false) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refresh(); self.finishBackgroundTasks() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext); self.finishBackgroundTasks() }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.receive(userInfo); self.finishBackgroundTasks() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message); self.finishBackgroundTasks() }
    }
}
