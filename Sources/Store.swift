import Foundation
import SwiftUI
#if !SYNC_TESTING
import WidgetKit
import UIKit
#endif

/// 全部数据的读写与跨设备同步。
///
/// 存储做了三层保险，因为上一个 App 出过"当时看得见、重启就没了"的事：
///  1. 每次写盘后立刻回读并解码校验，失败就如实记下来，界面上能看到；
///  2. 每次覆盖前把旧文件留成 .bak，主文件坏了自动回退到备份；
///  3. 成功写入的条数记进 UserDefaults，下次启动时对比，
///     磁盘上的条数比上次少就当作异常，先救备份再说，绝不静默接受。
@MainActor
final class Store: ObservableObject {

    @Published var doses: [Dose] = []
    @Published var effects: [EffectLog] = []
    @Published var lifeEvents: [LifeEvent] = []
    @Published var doseEpisode: DoseEpisodeSelection? = nil
    @Published var days: [DayLog] = []
    @Published var supply = Supply()
    @Published var inventorySync = InventorySyncState()
    var inventoryNeedsReview: Bool { inventorySync.needsReview }
    @Published var settings = SyncedSettings()

    /// 可乐定单独落盘、单独走 iCloud 钥匙串服务，不进入主药数据包。
    @Published var clonidineEntries: [ClonidineEntry] = []
    @Published var clonidineSyncMessage: String = "尚未同步"
    private var clonidineTombstones: [String: Date] = [:]
    private var syncingClonidine = false
    private var clonidineStorageUsable = true

    /// 删除墓碑：业务键 -> 删除时刻
    @Published var tombstones: [String: Date] = [:]

    // 同步状态（只用于界面显示）
    @Published var syncMessage: String = "尚未同步"
    @Published var lastSyncAt: Date? = nil
    @Published var syncing = false

    // 存储自检（界面上直接显示，出问题第一时间看得见）
    @Published var storageOK = true
    @Published var storageMessage = "正常"
    @Published var lastWriteAt: Date? = nil
    @Published var recoveredFromBackup = false

    /// 刚刚快速记下的那一条，用于界面上显示"已记下 + 撤销"。
    /// 放在 Store 里而不是某个 View 的 @State，是因为从小组件点进来时也要能显示。
    @Published var lastQuickAdded: Dose? = nil

    private let fm = FileManager.default
    private let defaults: UserDefaults
    private let directoryOverride: URL?
    private let syncAutomatically: Bool

    private var dir: URL { directoryOverride ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private var dosesURL: URL { url("doses.json") }
    private var effectsURL: URL { url("effects.json") }
    private var lifeEventsURL: URL { url("life-events.json") }
    private var daysURL: URL { url("days.json") }
    private var supplyURL: URL { url("supply.json") }
    private var settingsURL: URL { url("settings.json") }
    private var tombURL: URL { url("tombstones.json") }
    private var syncMetaURL: URL { url("syncmeta.json") }

    init(directory: URL? = nil, defaults: UserDefaults = .standard, syncAutomatically: Bool = true) {
        self.directoryOverride = directory
        self.defaults = defaults
        self.syncAutomatically = syncAutomatically
        load()
        guard syncAutomatically else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self else { return }
                #if !SYNC_TESTING
                if UIApplication.shared.applicationState == .active { self.sync() }
                #endif
            }
        }
    }

    deinit {
        pollTask?.cancel()
        pushTask?.cancel()
    }

    var status: DoseStatus { DoseStatus.compute(doses: doses, curve: settings.plasmaCurve) }

    /// 全部已发生的剂量都参与模型；曲线视窗独立决定，不删除较早贡献。
    func activeStack(at now: Date = Date()) -> [Dose] {
        doses.filter { $0.at <= now }.sorted { $0.at < $1.at }
    }
    var stats: DoseStats { DoseStats(doses: doses, effects: effects, days: days) }

    // MARK: - 加固的读写

    /// 写一个文件：先写临时文件 → 回读校验 → 旧文件转成 .bak → 就位。
    /// 任何一步失败都返回 false，并把原因写进 storageMessage。
    @discardableResult
    private func write<T: Codable>(_ value: T, to url: URL, label: String) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(value) else {
            fail("\(label)：编码失败"); return false
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // 回读校验：光写成功不算数，必须能原样读回来才算存住了
            let back = try Data(contentsOf: tmp)
            _ = try JSONDecoder().decode(T.self, from: back)
            guard back == data else {
                fail("\(label)：回读内容不符"); return false
            }
            let bak = url.appendingPathExtension("bak")
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: bak)
                try? fm.moveItem(at: url, to: bak)
            }
            try fm.moveItem(at: tmp, to: url)
            lastWriteAt = Date()
            if !storageOK { storageOK = true; storageMessage = "正常" }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            fail("\(label)：\(error.localizedDescription)")
            return false
        }
    }

    private func fail(_ msg: String) {
        storageOK = false
        storageMessage = msg
    }

    /// 读一个文件：主文件坏了自动退到 .bak，并如实标明用了备份
    private func read<T: Codable>(_ type: T.Type, from url: URL, label: String) -> T? {
        if let d = try? Data(contentsOf: url),
           let v = try? JSONDecoder().decode(type, from: d) { return v }
        let bak = url.appendingPathExtension("bak")
        if let d = try? Data(contentsOf: bak),
           let v = try? JSONDecoder().decode(type, from: d) {
            recoveredFromBackup = true
            storageMessage = "\(label)：主文件读不出，已从备份恢复"
            return v
        }
        return nil
    }

    // MARK: - 装载

    func load() {
        let expectedDoses = defaults.integer(forKey: "lastDoseCount")
        let expectedLifeEvents = defaults.integer(forKey: "lastLifeEventCount")
        tombstones = read([String: Date].self, from: tombURL, label: "墓碑") ?? [:]
        lastSyncAt = read(Date.self, from: syncMetaURL, label: "同步时间")

        doses   = read([Dose].self,      from: dosesURL,    label: "服药记录") ?? []
        effects = read([EffectLog].self, from: effectsURL,  label: "效果记录") ?? []
        lifeEvents = read([LifeEvent].self, from: lifeEventsURL, label: "进食与睡眠记录") ?? []
        doseEpisode = read(DoseEpisodeSelection.self, from: url("dose-episode.json"), label: "本波服药起点")
        days    = read([DayLog].self,    from: daysURL,     label: "每日记录") ?? []
        supply  = read(Supply.self,      from: supplyURL,   label: "库存")     ?? Supply()
        inventorySync = read(InventorySyncState.self, from: url("inventory-sync.json"), label: "库存核对状态") ?? InventorySyncState()
        settings = read(SyncedSettings.self, from: settingsURL, label: "设置") ?? SyncedSettings()

        if let checkpoint = read(SyncPayload.self, from: url("durable-state.json"), label: "完整备份") {
            // 两份来源都已在本机落盘；磁盘暂时不能再写，也必须显示已保存的记录。
            restoreInMemory(SyncMerge.merge(local: checkpoint, remote: localPayload))
            persistCurrentPayload()
        }
        let clonidineURL = url("clonidine-durable-state.json")
        let clonidineBackupURL = clonidineURL.appendingPathExtension("bak")
        if let clonidine = read(ClonidineSnapshot.self, from: clonidineURL, label: "可乐定记录") {
            clonidineEntries = clonidine.entries.sorted { $0.at < $1.at }
            clonidineTombstones = clonidine.tombstones
        } else {
            if fm.fileExists(atPath: clonidineURL.path) || fm.fileExists(atPath: clonidineBackupURL.path) {
                clonidineStorageUsable = false
                fail("可乐定记录主文件与备份都无法读取，已暂停覆盖")
            }
            clonidineEntries = []
            clonidineTombstones = [:]
        }
        recoverWatchImport()
        checkCounts(expectedDoses: expectedDoses, expectedLifeEvents: expectedLifeEvents)
        publish()
        Notifier.reschedule(self)
        if syncAutomatically { sync() }
    }

    /// 条数守卫：磁盘上比上次成功写入时少了，就是出事了，如实报出来。
    private func checkCounts(expectedDoses: Int, expectedLifeEvents: Int) {
        if expectedDoses > 0 && doses.count < expectedDoses {
            storageOK = false
            storageMessage = "记录条数异常：上次是 \(expectedDoses) 条，现在只读到 \(doses.count) 条"
            defaults.set(expectedDoses, forKey: "lastDoseCount")
        } else {
            defaults.set(doses.count, forKey: "lastDoseCount")
        }
        if expectedLifeEvents > 0 && lifeEvents.count < expectedLifeEvents {
            fail("进食与睡眠记录条数异常：上次是 \(expectedLifeEvents) 条，现在只读到 \(lifeEvents.count) 条")
            defaults.set(expectedLifeEvents, forKey: "lastLifeEventCount")
        } else {
            defaults.set(lifeEvents.count, forKey: "lastLifeEventCount")
        }
    }

    @discardableResult
    private func saveDoses() -> Bool {
        if write(doses.sorted { $0.at < $1.at }, to: dosesURL, label: "服药记录") {
            defaults.set(doses.count, forKey: "lastDoseCount")
            return true
        }
        return false
    }
    @discardableResult private func saveEffects() -> Bool { write(effects.sorted { $0.at < $1.at }, to: effectsURL, label: "效果记录") }
    @discardableResult private func saveLifeEvents() -> Bool {
        if write(lifeEvents.sorted { $0.at < $1.at }, to: lifeEventsURL, label: "进食与睡眠记录") {
            defaults.set(lifeEvents.count, forKey: "lastLifeEventCount")
            return true
        }
        return false
    }
    @discardableResult private func saveDays() -> Bool { write(days.sorted { $0.date < $1.date }, to: daysURL, label: "每日记录") }
    @discardableResult private func saveSupply() -> Bool {
        inventorySync.observe(supply)
        let supplySaved = write(supply, to: supplyURL, label: "库存")
        let reviewSaved = write(inventorySync, to: url("inventory-sync.json"), label: "库存核对状态")
        return supplySaved && reviewSaved
    }
    @discardableResult private func saveSettings() -> Bool { write(settings, to: settingsURL, label: "设置") }
    @discardableResult private func saveTombstones() -> Bool { write(tombstones, to: tombURL, label: "墓碑") }

    // MARK: - 服药记录

    /// 手动选择已发生的实记服药；不新增记录。自动间隔分波由 DoseEpisode 按设置计算。
    @discardableResult
    func selectDoseEpisode(startingAt doseID: UUID?, now: Date = Date()) -> Bool {
        if let doseID {
            guard let dose = doses.first(where: { $0.id == doseID }),
                  dose.at.timeIntervalSince1970.isFinite, dose.at <= now else { return false }
        }
        var payload = localPayload
        payload.doseEpisode = DoseEpisodeSelection(doseID: doseID, updatedAt: now)
        guard write(payload, to: url("durable-state.json"), label: "本波服药起点") else { return false }
        doseEpisode = payload.doseEpisode
        if !saveDoseEpisode() { fail("服药起点已保存，兼容备份暂未写入；完整备份可恢复") }
        pushSoon()
        return true
    }

    private func saveDoseEpisode() -> Bool {
        guard let doseEpisode else { return true }
        return write(doseEpisode, to: url("dose-episode.json"), label: "本波服药起点")
    }

    /// 快速记一次：默认此刻、默认剂量。这是最常用的入口，一步完成。
    @discardableResult
    func quickTake(at time: Date = Date()) -> Dose {
        var d = Dose(at: time, mg: settings.defaultMg, pillCount: 1)
        d.updatedAt = Date()
        doses.append(d)
        doses.sort { $0.at < $1.at }
        // 记了药就说明今天没跳过
        if let i = days.firstIndex(where: { $0.date == d.dateOnly }), days[i].skipped {
            days[i].skipped = false
            days[i].updatedAt = Date()
            saveDays()
        }
        if saveDoses() {
            MedicationShareRepository.shared.publishNewDose(
                d, roundGapHours: settings.newRoundGapHours, previousDoseAt: previousDoseDate(before: d))
        }
        lastQuickAdded = d
        after()
        return d
    }

    /// Watch 的队列可能重复送达同一事件；稳定 UUID 和墓碑保证不重复记药/扣库存。
    /// 先持久化可重放的导入日志，崩溃或写入失败后也能完成同一事务。
    @discardableResult
    func acceptWatchDose(id: UUID, at: Date, mg: Int, med: String, recordedAt: Date) -> Bool {
        guard (5...140).contains(mg), mg % 5 == 0, !med.isEmpty,
              at.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970.isFinite else { return false }
        guard recoverWatchImport() else { return false }
        let key = "d:" + id.uuidString
        if tombstones[key] != nil { return persistCurrentPayload() }
        if let existing = doses.first(where: { $0.id == id }) {
            let sameEvent = existing.at == at && existing.mg == mg && existing.med == med
            let editedLater = (existing.updatedAt ?? .distantPast) > recordedAt
            guard sameEvent || editedLater else { return false }
            return persistCurrentPayload()
        }

        var dose = Dose(at: at, mg: mg, med: med)
        dose.id = id
        dose.updatedAt = recordedAt
        var transaction = SyncPayload()
        transaction.doses = [dose]
        // 库存追踪暂停；只接收服药事件，保留已有库存原值。
        if var day = days.first(where: { $0.date == dose.dateOnly }), day.skipped {
            day.skipped = false
            day.updatedAt = Date()
            transaction.days = [day]
        }
        guard write(transaction, to: url("watch-import.json"), label: "手表记录接收") else { return false }
        guard recoverWatchImport() else { return false }
        after()
        return true
    }

    @discardableResult
    private func recoverWatchImport() -> Bool {
        let journal = url("watch-import.json")
        guard fm.fileExists(atPath: journal.path) else { return true }
        guard let data = try? Data(contentsOf: journal),
              let transaction = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
            fail("手表接收日志无法读取，暂缓确认")
            return false
        }
        let existingIDs = Set(doses.map(\.id))
        guard apply(SyncMerge.merge(local: localPayload, remote: transaction)) else { return false }
        for dose in transaction.doses where !existingIDs.contains(dose.id) {
            MedicationShareRepository.shared.publishNewDose(
                dose, roundGapHours: settings.newRoundGapHours, previousDoseAt: previousDoseDate(before: dose))
        }
        do { try fm.removeItem(at: journal) } catch { return false }
        return true
    }

    func add(_ dose: Dose) {
        var d = dose
        d.updatedAt = Date()
        tombstones.removeValue(forKey: d.syncKey)
        doses.append(d)
        doses.sort { $0.at < $1.at }
        let saved = saveDoses()
        saveTombstones()
        if saved {
            MedicationShareRepository.shared.publishNewDose(
                d, roundGapHours: settings.newRoundGapHours, previousDoseAt: previousDoseDate(before: d))
        }
        after()
    }

    func update(_ dose: Dose) {
        guard let i = doses.firstIndex(where: { $0.id == dose.id }) else { return }
        var d = dose
        d.updatedAt = Date()
        doses[i] = d
        doses.sort { $0.at < $1.at }
        if saveDoses() {
            MedicationShareRepository.shared.publishIfShared(d, roundGapHours: settings.newRoundGapHours)
        }
        after()
    }

    private func previousDoseDate(before dose: Dose) -> Date? {
        doses.filter { $0.id != dose.id && $0.at < dose.at }
            .max { $0.at < $1.at }?.at
    }

    func delete(_ dose: Dose) {
        if lastQuickAdded?.id == dose.id { lastQuickAdded = nil }
        doses.removeAll { $0.id == dose.id }
        tombstones[dose.syncKey] = Date()
        let saved = saveDoses()
        saveTombstones()
        if saved { MedicationShareRepository.shared.removeIfShared(dose.id) }
        after()
    }

    // MARK: - 独立的可乐定记录

    private var clonidineSnapshot: ClonidineSnapshot {
        ClonidineSnapshot(entries: clonidineEntries, tombstones: clonidineTombstones,
                          updatedAt: Date(), deviceName: ClonidineSyncStore.deviceName)
    }

    @discardableResult
    private func saveClonidineSnapshot(_ snapshot: ClonidineSnapshot) -> Bool {
        guard clonidineStorageUsable else { return false }
        guard write(snapshot, to: url("clonidine-durable-state.json"), label: "可乐定记录") else { return false }
        clonidineEntries = snapshot.entries.sorted { $0.at < $1.at }
        clonidineTombstones = snapshot.tombstones
        return true
    }

    @discardableResult
    func addClonidine(_ entry: ClonidineEntry) -> Bool {
        guard entry.mg > .zero, entry.at.timeIntervalSince1970.isFinite,
              entry.note.count <= 500 else { return false }
        var next = clonidineSnapshot
        var saved = entry
        saved.updatedAt = Date()
        next.entries.removeAll { $0.id == saved.id }
        next.tombstones.removeValue(forKey: saved.syncKey)
        next.entries.append(saved)
        guard saveClonidineSnapshot(next) else { return false }
        syncClonidine()
        return true
    }

    @discardableResult
    func updateClonidine(_ entry: ClonidineEntry) -> Bool {
        guard clonidineEntries.contains(where: { $0.id == entry.id }), entry.mg > .zero,
              entry.at.timeIntervalSince1970.isFinite, entry.note.count <= 500 else { return false }
        var next = clonidineSnapshot
        var saved = entry
        saved.updatedAt = Date()
        next.entries.removeAll { $0.id == saved.id }
        next.entries.append(saved)
        guard saveClonidineSnapshot(next) else { return false }
        syncClonidine()
        return true
    }

    @discardableResult
    func deleteClonidine(_ entry: ClonidineEntry) -> Bool {
        var next = clonidineSnapshot
        next.entries.removeAll { $0.id == entry.id }
        next.tombstones[entry.syncKey] = Date()
        guard saveClonidineSnapshot(next) else { return false }
        syncClonidine()
        return true
    }

    // MARK: - 效果记录

    @discardableResult
    func add(_ log: EffectLog) -> Bool { saveEffect(log) }

    @discardableResult
    func update(_ log: EffectLog) -> Bool {
        guard effects.contains(where: { $0.id == log.id }) else { return false }
        return saveEffect(log)
    }

    /// 先保存完整快照再更新界面；失败时编辑器保留用户输入。
    @discardableResult
    func saveEffect(_ log: EffectLog) -> Bool {
        var e = log
        e.updatedAt = Date()
        if e.doseID == nil || effects.first(where: { $0.id == e.id })?.at != e.at {
            e.doseID = relatedDose(at: e.at)?.id
        }
        var payload = localPayload
        payload.effects.removeAll { $0.id == e.id }
        payload.effects.append(e)
        payload.tombstones.removeValue(forKey: e.syncKey)
        return commitEffects(payload)
    }

    @discardableResult
    func delete(_ log: EffectLog) -> Bool {
        var payload = localPayload
        payload.effects.removeAll { $0.id == log.id }
        payload.tombstones[log.syncKey] = Date()
        return commitEffects(payload)
    }

    func relatedDose(at time: Date) -> Dose? {
        doses.filter { $0.at <= time && time.timeIntervalSince($0.at) < 24 * 3600 }
            .max { $0.at < $1.at }
    }

    /// 手表只上传文字感受；稳定 UUID 与删除墓碑使重传安全。
    @discardableResult
    func acceptWatchNote(id: UUID, at: Date, note: String, recordedAt: Date) -> Bool {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.count <= 500, note.utf8.count <= 2_000,
              at.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970.isFinite else { return false }
        guard recoverWatchImport() else { return false }
        let key = "e:" + id.uuidString
        if tombstones[key] != nil { return persistCurrentPayload() }
        if let existing = effects.first(where: { $0.id == id }) {
            let sameEvent = existing.at == at && existing.note == note
            let editedLater = (existing.updatedAt ?? .distantPast) > recordedAt
            guard sameEvent || editedLater else { return false }
            return persistCurrentPayload()
        }
        var e = EffectLog(at: at)
        e.id = id
        e.updatedAt = recordedAt
        e.note = note
        e.doseID = relatedDose(at: at)?.id
        var payload = localPayload
        payload.effects.append(e)
        return commitEffects(payload)
    }

    private func commitEffects(_ payload: SyncPayload) -> Bool {
        guard write(payload, to: url("durable-state.json"), label: "感受笔记") else { return false }
        effects = payload.effects.sorted { $0.at < $1.at }
        tombstones = payload.tombstones
        // 完整快照已持久化。旧版兼容文件失败仍可在重启/同步时由快照恢复。
        let mirrorsSaved = [saveEffects(), saveTombstones()].allSatisfy { $0 }
        if !mirrorsSaved { fail("笔记已保存，兼容备份暂未完整写入；完整备份可恢复") }
        pushSoon()
        return true
    }

    // MARK: - 进食与睡眠记录

    /// 完整快照先落盘；保存失败不显示未保存的事件，也不会改变计时起点。
    @discardableResult
    func saveLifeEvent(_ event: LifeEvent) -> Bool {
        guard event.at.timeIntervalSince1970.isFinite else {
            fail("进食与睡眠记录：时间无效")
            return false
        }
        var e = event
        e.updatedAt = Date()
        var payload = localPayload
        payload.lifeEvents.removeAll { $0.id == e.id }
        payload.lifeEvents.append(e)
        payload.tombstones.removeValue(forKey: e.syncKey)
        return commitLifeEvents(payload)
    }

    @discardableResult
    func delete(_ event: LifeEvent) -> Bool {
        var payload = localPayload
        payload.lifeEvents.removeAll { $0.id == event.id }
        payload.tombstones[event.syncKey] = Date()
        return commitLifeEvents(payload)
    }

    private func commitLifeEvents(_ payload: SyncPayload) -> Bool {
        guard write(payload, to: url("durable-state.json"), label: "进食与睡眠记录") else { return false }
        lifeEvents = payload.lifeEvents.sorted { $0.at < $1.at }
        tombstones = payload.tombstones
        defaults.set(lifeEvents.count, forKey: "lastLifeEventCount")
        let mirrorsSaved = [saveLifeEvents(), saveTombstones()].allSatisfy { $0 }
        if !mirrorsSaved { fail("进食与睡眠记录已保存，兼容备份暂未完整写入；完整备份可恢复") }
        pushSoon()
        return true
    }

    // MARK: - 每日记录

    func dayLog(for date: DateOnly) -> DayLog {
        days.first { $0.date == date } ?? DayLog(date: date)
    }

    func save(_ log: DayLog) {
        var l = log
        l.updatedAt = Date()
        if let i = days.firstIndex(where: { $0.date == l.date }) { days[i] = l } else { days.append(l) }
        days.sort { $0.date < $1.date }
        saveDays()
        after()
    }

    /// 今天主动不吃
    func markSkipped(_ date: DateOnly = .today(), reason: String = "") {
        var l = dayLog(for: date)
        l.skipped = true
        l.skipReason = reason
        save(l)
    }

    func unmarkSkipped(_ date: DateOnly = .today()) {
        var l = dayLog(for: date)
        l.skipped = false
        l.skipReason = ""
        save(l)
    }

    var skippedToday: Bool { dayLog(for: .today()).skipped }

    // MARK: - 库存与设置

    func updateSupply(_ s: Supply, resolvesConflict: Bool = false) {
        var v = s
        v.updatedAt = Date()
        inventorySync.observe(supply)
        supply = v
        if resolvesConflict { inventorySync.resolvedAt = max(Date(), inventorySync.conflictAt ?? .distantPast) }
        saveSupply()
        after()
    }

    /// 配了一瓶新的
    func refill(pills: Int, on date: DateOnly = .today(), useRepeat: Bool = true) {
        var s = supply
        s.pillsLeft += pills
        s.lastFill = date
        if useRepeat && s.repeatsLeft > 0 { s.repeatsLeft -= 1 }
        s.updatedAt = Date()
        updateSupply(s)
    }

    func updateSettings(_ s: SyncedSettings) {
        var v = s
        v.updatedAt = Date()
        settings = v
        saveSettings()
        after()
    }

    /// 今天的目标服药时刻
    var targetToday: Date? {
        Calendar.current.date(bySettingHour: settings.targetHour,
                              minute: settings.targetMinute, second: 0, of: Date())
    }

    /// 今晚计划入睡的时刻
    var bedtimeTonight: Date? {
        Calendar.current.date(bySettingHour: settings.bedtimeHour,
                              minute: settings.bedtimeMinute, second: 0, of: Date())
    }

    /// 今天最晚该吃药的时刻。开了自动就按就寝倒推 14 小时，否则用手填的整点。
    var cutoffToday: Date? {
        if settings.autoCutoff, let bed = bedtimeTonight {
            return DoseEngine.latestTake(bedtime: bed)
        }
        return Calendar.current.date(bySettingHour: settings.lateCutoffHour,
                                     minute: 0, second: 0, of: Date())
    }

    // MARK: - 每次改动之后统一做的事

    private func after() {
        persistCurrentPayload()
        publish()
        Notifier.reschedule(self)
        pushSoon()
    }

    func publish() {
        #if !SYNC_TESTING
        var s = SharedSnapshot.empty
        s.status = status
        s.targetAt = nil
        s.pillsLeft = supply.pillsLeft
        s.daysToRefill = supply.daysToRefill
        s.skippedToday = skippedToday
        s.plasmaPeakTenthHoursOverride = settings.plasmaPeakTenthHoursOverride
        s.plasmaHalfLifeTenthHoursOverride = settings.plasmaHalfLifeTenthHoursOverride
        s.recentDoses = doses.filter { $0.at <= s.status.generatedAt }
            .sorted { $0.at < $1.at }
            .map { DoseTick(at: $0.at, mg: $0.mg, food: $0.food) }
        s.updatedAt = Date()
        SharedStore.save(s)
        WidgetCenter.shared.reloadTimelines(ofKind: "YaoShiWidget")
        if #available(iOS 16.2, *) { DoseActivityController.refresh(from: s, settings: settings) }
        #endif
    }

    // MARK: - 跨设备同步

    private var pushTask: Task<Void, Never>? = nil
    private var pollTask: Task<Void, Never>? = nil

    private var localPayload: SyncPayload {
        var p = SyncPayload()
        p.doses = doses
        p.effects = effects
        p.lifeEvents = lifeEvents
        p.doseEpisode = doseEpisode
        p.days = days
        p.supply = supply == Supply() ? nil : supply
        p.settings = settings
        p.tombstones = tombstones
        p.inventory = inventorySync
        return p
    }

    @discardableResult
    private func apply(_ p: SyncPayload) -> Bool {
        // 先存住跨设备合并结果，避免磁盘失败时把未保存的事件显示成已接收。
        guard write(p, to: url("durable-state.json"), label: "完整备份") else { return false }
        restoreInMemory(p)
        let saved = persistMirrors()
        publish()
        Notifier.reschedule(self)
        return saved
    }

    /// 仅供已读取的本机持久化数据，或已写入完整快照后的数据使用。
    private func restoreInMemory(_ p: SyncPayload) {
        doses = p.doses.sorted { $0.at < $1.at }
        effects = p.effects.sorted { $0.at < $1.at }
        lifeEvents = p.lifeEvents.sorted { $0.at < $1.at }
        doseEpisode = p.doseEpisode
        days = p.days.sorted { $0.date < $1.date }
        if let s = p.supply { supply = s }
        if let state = p.inventory { inventorySync = state }
        if let s = p.settings { settings = s }
        tombstones = p.tombstones
    }

    /// 先原子保存整包供重启恢复，再更新兼容旧版的各个文件。
    /// 每次发快照/接收回执前重新确认，不能只凭内存里已有记录就 ACK。
    @discardableResult
    private func persistCurrentPayload() -> Bool {
        inventorySync.observe(supply)
        guard write(localPayload, to: url("durable-state.json"), label: "完整备份") else { return false }
        return persistMirrors()
    }

    private func persistMirrors() -> Bool {
        let saved = [saveDoses(), saveEffects(), saveLifeEvents(), saveDoseEpisode(), saveDays(), saveSupply(), saveSettings(), saveTombstones()].allSatisfy { $0 }
        if !saved { fail("数据未完整写入，本轮暂停同步确认") }
        return saved
    }

    /// 连续操作停下来后，先读取并合并所有快照，再更新本机条目。
    func pushSoon() {
        guard syncAutomatically else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sync()
        }
    }

    private func markChecked() {
        lastSyncAt = Date()
        write(lastSyncAt, to: syncMetaURL, label: "同步检查时间")
    }

    /// 读取失败不按空数据处理；本机写入成功也不代表另一台已收到。
    func sync(using keychain: any SyncKeychainAccess = SystemSyncKeychain()) {
        syncClonidine()
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let before = SyncStore.fingerprint(localPayload)
        let read: SyncRead
        switch SyncStore.pull(using: keychain) {
        case .failure(let error):
            syncMessage = error.message
            writeSyncDiagnostics(read: nil, error: error)
            return
        case .success(let result): read = result
        }

        var merged = localPayload
        for key in read.snapshots.keys.sorted() {
            merged = SyncMerge.merge(local: merged, remote: read.snapshots[key]!)
        }
        let mergedHash = SyncStore.fingerprint(merged)
        if before != mergedHash, !apply(merged) {
            syncMessage = "合并记录未完整写入，本轮暂停上传"
            writeSyncDiagnostics(read: read, error: SyncFailure(message: syncMessage, status: nil))
            return
        }
        guard persistCurrentPayload() else {
            syncMessage = "本机记录未完整写入，本轮暂停上传和确认"
            writeSyncDiagnostics(read: read, error: SyncFailure(message: syncMessage, status: nil))
            return
        }
        var outgoing = localPayload
        let hash = SyncStore.fingerprint(outgoing)
        outgoing.acknowledged = read.peers.mapValues { SyncStore.fingerprint($0) }
        let result = SyncStore.push(outgoing, using: keychain)
        guard result.isOK else {
            syncMessage = result.message
            writeSyncDiagnostics(read: read, error: result.error)
            return
        }

        let confirmed = read.peers.values.filter { $0.acknowledged?[SyncStore.account] == hash }.count
        if confirmed > 0 {
            syncMessage = "已获 \(confirmed) 台设备接收确认"
        } else if !read.peers.isEmpty {
            syncMessage = before != hash ? "已收到其他设备的记录，等待对方确认" : "已读到其他设备，等待本次接收确认"
        } else {
            syncMessage = "本机已提交，尚未读到其他设备"
        }
        markChecked()
        writeSyncDiagnostics(read: read, error: nil)
    }

    /// 可乐定使用独立钥匙串服务；失败时保留本机文件，不影响主药同步。
    func syncClonidine(using keychain: any SyncKeychainAccess = SystemSyncKeychain()) {
        guard syncAutomatically, !syncingClonidine else { return }
        syncingClonidine = true
        defer { syncingClonidine = false }

        let before = ClonidineSnapshot.fingerprint(clonidineSnapshot)
        let remote: [String: ClonidineSnapshot]
        switch ClonidineSyncStore.pull(using: keychain) {
        case .failure(let error):
            clonidineSyncMessage = error.message
            return
        case .success(let snapshots):
            remote = snapshots
        }

        var merged = clonidineSnapshot
        for key in remote.keys.sorted() {
            if let snapshot = remote[key] { merged = ClonidineSnapshot.merge(merged, snapshot) }
        }
        if before != ClonidineSnapshot.fingerprint(merged), !saveClonidineSnapshot(merged) {
            clonidineSyncMessage = "合并未写入，可乐定本机记录仍保留"
            return
        }

        var outgoing = clonidineSnapshot
        outgoing.updatedAt = Date()
        outgoing.deviceName = ClonidineSyncStore.deviceName
        switch ClonidineSyncStore.push(outgoing, using: keychain) {
        case .failure(let error): clonidineSyncMessage = error.message
        case .success:
            clonidineSyncMessage = remote.isEmpty ? "已提交到 iCloud 钥匙串" : "已提交；读取到 \(remote.count) 台设备快照"
        }
    }

    func syncNow() {
        syncMessage = "正在检查…"
        sync()
    }

    var syncStatusLine: String {
        guard let t = lastSyncAt else { return syncMessage }
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return syncMessage + " · 检查 " + f.string(from: t)
    }

    /// 仅保存匿名槽位、条数与摘要，用于真机核验，不包含服药明细或设备姓名。
    private func writeSyncDiagnostics(read: SyncRead?, error: SyncFailure?) {
        let payload = localPayload
        let hash = SyncStore.fingerprint(payload)
        var report: [String: Any] = [
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "account": SyncStore.account,
            "recordCount": payload.doses.count + payload.effects.count + payload.lifeEvents.count + payload.days.count,
            "contentHash": hash,
            "inventoryNeedsReview": inventoryNeedsReview,
            "message": syncMessage,
            "peers": (read?.peers ?? [:]).keys.sorted().map { key -> [String: Any] in
                let peer = read!.peers[key]!
                return ["account": key, "recordCount": peer.doses.count + peer.effects.count + peer.lifeEvents.count + peer.days.count,
                        "contentHash": SyncStore.fingerprint(peer),
                        "confirmedCurrentContent": peer.acknowledged?[SyncStore.account] == hash]
            }
        ]
        if let error {
            report["error"] = error.message
            if let code = error.status { report["osStatus"] = Int(code) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url("syncdiagnostics.json"), options: .atomic)
        }
    }

    // MARK: - 存储自检信息（设置页显示）

    var storageReport: [(String, String)] {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm:ss"
        var out: [(String, String)] = []
        out.append(("服药记录", "\(doses.count) 条"))
        out.append(("可乐定记录", "\(clonidineEntries.count) 条 · \(clonidineSyncMessage)"))
        out.append(("效果记录", "\(effects.count) 条"))
        out.append(("进食与睡眠记录", "\(lifeEvents.count) 条"))
        out.append(("每日记录", "\(days.count) 条"))
        if let a = lastWriteAt { out.append(("最后写盘", f.string(from: a))) }
        if let attrs = try? fm.attributesOfItem(atPath: dosesURL.path),
           let size = attrs[.size] as? Int {
            out.append(("记录文件", "\(size) 字节"))
        } else {
            out.append(("记录文件", "还没有（尚未记录过）"))
        }
        out.append(("状态", storageOK ? "正常" : storageMessage))
        if recoveredFromBackup { out.append(("备份", "本次启动用了备份文件")) }
        return out
    }
}
