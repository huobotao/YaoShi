import SwiftUI

@MainActor
final class StandaloneStore: ObservableObject {
    @Published private(set) var data: StandaloneImport?
    @Published private(set) var error: String?
    @Published private(set) var complicationReady = false
    @Published private(set) var localDoses: [StandaloneDose] = []
    @Published private(set) var journalError: String?

    private var journal: DoseJournal?

    init() {
        do {
            let opened = try DoseJournal(url: DoseJournal.defaultURL())
            journal = opened
            localDoses = opened.activeLocalDoses()
        } catch {
            // Never create a replacement journal when an existing one cannot be read.
            journalError = "手表服药日志无法读取；为保护旧记录，暂不能新增服药。"
        }
    }

    var canRecord: Bool { journal != nil }
    var latestLocalDose: StandaloneDose? { localDoses.max { $0.at < $1.at } }
    var pendingCount: Int {
        guard let journal else { return 0 }
        let imported = data?.doses ?? []
        return journal.pendingDoses(imported: imported).count
            + journal.pendingRemovalIDs(imported: imported).count
    }
    var displayData: StandaloneImport? {
        guard let data, let journal else { return data }
        return StandaloneImport(schema: data.schema,
                                sourceCapturedAt: data.sourceCapturedAt,
                                exportedAt: data.exportedAt,
                                sourceSHA256: data.sourceSHA256,
                                peakHours: data.peakHours,
                                halfLifeHours: data.halfLifeHours,
                                doses: journal.mergedDoses(imported: data.doses))
    }

    func recordDose(at date: Date) {
        guard let journal else { return }
        // Confirmation is required by the view; this also catches a second tap
        // immediately after dismissing the first confirmation.
        if let latest = latestLocalDose, abs(date.timeIntervalSince(latest.at)) < 60 {
            journalError = "刚刚已记录一条服药；如需修改，请先核对下方记录。"
            return
        }
        do {
            try journal.record(at: date, mg: 50)
            localDoses = journal.activeLocalDoses()
            if data != nil { complicationReady = ComplicationSnapshot.publishLocal(journal) }
            journalError = nil
        } catch {
            journalError = "保存失败，未添加服药记录。请稍后重试。"
        }
    }

    func removeLocalDose(_ id: UUID) {
        guard let journal else { return }
        do {
            try journal.remove(id)
            localDoses = journal.activeLocalDoses()
            if data != nil { complicationReady = ComplicationSnapshot.publishLocal(journal) }
            journalError = nil
        } catch {
            journalError = "撤销失败，原记录仍保留。"
        }
    }

    func reviseLocalDose(_ id: UUID, mg: Int) {
        guard let journal, let old = localDoses.first(where: { $0.id == id }) else { return }
        do {
            try journal.revise(id, at: old.at, mg: mg, food: old.food)
            localDoses = journal.activeLocalDoses()
            if data != nil { complicationReady = ComplicationSnapshot.publishLocal(journal) }
            journalError = nil
        } catch {
            journalError = "修改剂量失败，原记录仍保留。"
        }
    }

    private var importURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("standalone-import-v1.json")
    }
    private var lastGoodURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YaoShi-Standalone-Air-R4/last-good-v1.json")
    }

    private func readValidated(_ url: URL) throws -> StandaloneImport {
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 2_000_000 else { throw StandaloneImport.ImportError.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidate = try decoder.decode(StandaloneImport.self, from: bytes)
        try candidate.validate()
        return candidate
    }

    func reload() {
        do {
            let bytes = try Data(contentsOf: importURL)
            guard bytes.count <= 2_000_000 else { throw StandaloneImport.ImportError.invalid }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let candidate = try decoder.decode(StandaloneImport.self, from: bytes)
            try candidate.validate()
            if let prior = try? readValidated(lastGoodURL),
               candidate.sourceCapturedAt < prior.sourceCapturedAt {
                throw StandaloneImport.ImportError.invalid
            }
            try FileManager.default.createDirectory(at: lastGoodURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: lastGoodURL, options: .atomic)
            _ = try readValidated(lastGoodURL)
            data = candidate
            error = nil
            complicationReady = ComplicationSnapshot.publish(candidate)
            if let journal { complicationReady = ComplicationSnapshot.publishLocal(journal) && complicationReady }
        } catch {
            // Never replace an already validated in-memory copy with a bad import.
            if data == nil { data = try? readValidated(lastGoodURL) }
            self.error = data == nil ? "尚无有效数据。请从电脑导入已备份的 Air 记录。" : "新导入文件无效；仍显示上次已核验的数据。"
            complicationReady = data.map(ComplicationSnapshot.publish) ?? false
            if let journal { complicationReady = ComplicationSnapshot.publishLocal(journal) && complicationReady }
        }
    }
}

@main
struct YaoShiStandaloneWatchApp: App {
    @StateObject private var store = StandaloneStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            StandaloneCurveView()
                .environmentObject(store)
                .onAppear { store.reload() }
                .onChange(of: phase) { _, next in if next == .active { store.reload() } }
        }
    }
}

struct StandaloneCurveView: View {
    @EnvironmentObject private var store: StandaloneStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var heartRate = HeartRateStore()
    @State private var showingDoseConfirmation = false
    @State private var confirmationTime = Date()
    @State private var doseToUndo: UUID?
    @State private var doseToEdit: UUID?
    @State private var editedMg = 50
    @State private var showingDoseEditor = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("药时")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let data = store.displayData {
                            let level = StandaloneCurve.level(data, at: now)
                            let last = data.doses.filter { $0.at <= now }.max { $0.at < $1.at }
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(String(format: "%.2f 倍", level))
                                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                                    .monospacedDigit().foregroundStyle(.mint)
                                Spacer(minLength: 0)
                                Text("模型估算")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            CurvePlot(points: StandaloneCurve.points(data, now: now), now: now)
                                .frame(height: 60)
                            doseControls
                            heartRatePanel(now: now)
                            if let last {
                                Text("上次服药：\(last.at.formatted(.dateTime.month().day().hour().minute()))")
                                    .font(.caption2)
                            }
                            Text("数据截至 \(data.sourceCapturedAt.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                            if now.timeIntervalSince(data.sourceCapturedAt) > 2 * 3600 {
                                Text("手机快照超过 2 小时：手机新增服药不会自动出现；手表本地记录已计入曲线。")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Text("参数：达峰 \(data.peakHours.formatted()) 小时 · 半衰期 \(data.halfLifeHours.formatted()) 小时")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.largeTitle).foregroundStyle(.mint)
                            doseControls
                            heartRatePanel(now: now)
                        }
                        if let error = store.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                        if let error = store.journalError { Text(error).font(.caption2).foregroundStyle(.red) }
                        if store.data != nil && !store.complicationReady {
                            Text("表盘数据暂不可用；请在药时手表 App 内核对记录。")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Text("离线计算；不会向 iPhone 写入记录。仅供记录参考，不是血液检测或用药建议。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("重新读取导入文件") { store.reload() }.font(.caption2)
                    }
                    .padding(.horizontal, 2).padding(.bottom, 10)
                }
                .background(Color.black)
            }
            .onAppear { heartRate.startObserving() }
            .onChange(of: scenePhase) { _, next in
                if next == .active { heartRate.startObserving() }
                else { heartRate.stopObserving() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                if scenePhase == .active { heartRate.refresh() }
            }
            .alert("确认服药", isPresented: $showingDoseConfirmation) {
                Button("记录已服 50 mg") { store.recordDose(at: confirmationTime) }
                Button("取消", role: .cancel) { }
            } message: {
                Text("Vyvanse 50 mg · \(confirmationTime.formatted(.dateTime.month().day().hour().minute()))。确认后仅保存在这只手表，尚未同步到 iPhone。")
            }
            .confirmationDialog("撤销这条手表服药记录？", isPresented: Binding(
                get: { doseToUndo != nil },
                set: { if !$0 { doseToUndo = nil } }
            )) {
                Button("撤销记录", role: .destructive) {
                    if let id = doseToUndo { store.removeLocalDose(id) }
                    doseToUndo = nil
                }
                Button("取消", role: .cancel) { doseToUndo = nil }
            } message: {
                Text("会从当前曲线中移除；日志仍保留撤销痕迹。不会更改 iPhone 数据。")
            }
            .sheet(isPresented: $showingDoseEditor) {
                VStack(spacing: 8) {
                    Text("修改手表记录剂量").font(.headline)
                    Picker("剂量", selection: $editedMg) {
                        ForEach(Array(stride(from: 5, through: 500, by: 5)), id: \.self) { mg in
                            Text("\(mg) mg").tag(mg)
                        }
                    }
                    .labelsHidden()
                    Button("保存修改") {
                        if let id = doseToEdit { store.reviseLocalDose(id, mg: editedMg) }
                        showingDoseEditor = false
                    }
                    Button("取消") { showingDoseEditor = false }
                        .buttonStyle(.borderless)
                }
                .padding()
            }
    }

    private var doseControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                confirmationTime = Date()
                showingDoseConfirmation = true
            } label: {
                Label("记录已服 50 mg", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(!store.canRecord)

            if store.pendingCount > 0 {
                Text("仅手表已保存 · 待同步手机（\(store.pendingCount) 条）")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            if let latest = store.latestLocalDose {
                HStack(spacing: 4) {
                    Text("手表记录：\(latest.at.formatted(.dateTime.month().day().hour().minute())) · \(latest.mg) mg")
                        .font(.system(size: 10))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("改剂量") {
                        doseToEdit = latest.id
                        editedMg = latest.mg
                        showingDoseEditor = true
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    Button("撤销") { doseToUndo = latest.id }
                        .font(.system(size: 10))
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func heartRatePanel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("♥ 心率")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                Spacer(minLength: 3)
                if let reading = heartRate.latest {
                    Text("\(reading.bpm) 次/分")
                        .font(.headline).monospacedDigit().foregroundStyle(.red)
                } else {
                    Text("暂无读数").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let reading = heartRate.latest {
                HStack(spacing: 3) {
                    Text("测于 \(reading.measuredAt.formatted(.dateTime.hour().minute()))")
                    if now.timeIntervalSince(reading.measuredAt) > 10 * 60 { Text("· 已超过 10 分钟") }
                    Spacer(minLength: 0)
                    if let average = heartRate.averageLastHour { Text("近 1 小时均值 \(average)") }
                }
                .font(.system(size: 10))
                .foregroundStyle(now.timeIntervalSince(reading.measuredAt) > 10 * 60 ? .orange : .secondary)
            }
            if !heartRate.message.isEmpty {
                Text(heartRate.message).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if heartRate.shouldOfferAuthorization {
                Button("允许读取心率") { heartRate.requestAccess() }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                Button("刷新心率") { heartRate.refresh() }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
            }
        }
        .padding(7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CurvePlot: View {
    let points: [StandaloneCurve.Point]
    let now: Date
    var body: some View {
        Canvas { context, size in
            guard points.count > 1, let first = points.first, let last = points.last else { return }
            let span = max(1, last.at.timeIntervalSince(first.at))
            let ceiling = max(1.15, (points.map(\.level).max() ?? 0) * 1.12)
            func position(_ point: StandaloneCurve.Point) -> CGPoint {
                CGPoint(x: CGFloat(point.at.timeIntervalSince(first.at) / span) * size.width,
                        y: size.height - CGFloat(point.level / ceiling) * (size.height - 8))
            }
            var history = Path(); var future = Path()
            for (index, point) in points.enumerated() {
                let p = position(point)
                if index == 0 { history.move(to: p) }
                else if point.at <= now { history.addLine(to: p) }
                else if future.isEmpty { future.move(to: position(points[index - 1])); future.addLine(to: p) }
                else { future.addLine(to: p) }
            }
            context.stroke(history, with: .color(.mint), lineWidth: 2)
            context.stroke(future, with: .color(.mint.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let nowX = CGFloat(now.timeIntervalSince(first.at) / span) * size.width
            if nowX >= 0 && nowX <= size.width {
                let before = points.last { $0.at <= now } ?? first
                let after = points.first { $0.at >= now } ?? last
                let fraction = after.at > before.at
                    ? now.timeIntervalSince(before.at) / after.at.timeIntervalSince(before.at)
                    : 0
                let interpolated = before.level + (after.level - before.level) * fraction
                let nowY = size.height - CGFloat(interpolated / ceiling) * (size.height - 8)
                var marker = Path()
                marker.move(to: CGPoint(x: nowX, y: 13))
                marker.addLine(to: CGPoint(x: nowX, y: size.height))
                context.stroke(marker, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                context.fill(Path(ellipseIn: CGRect(x: nowX - 3.5, y: nowY - 3.5, width: 7, height: 7)), with: .color(.white))
                let label = context.resolve(Text("现在").font(.system(size: 10)).foregroundColor(.white))
                context.draw(label, at: CGPoint(x: min(size.width - 16, max(16, nowX)), y: 6))
            }
        }
    }
}
