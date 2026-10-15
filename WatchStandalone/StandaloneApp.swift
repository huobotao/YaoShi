import SwiftUI

@MainActor
final class StandaloneStore: ObservableObject {
    @Published private(set) var data: StandaloneImport?
    @Published private(set) var error: String?
    @Published private(set) var complicationReady = false

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
        } catch {
            // Never replace an already validated in-memory copy with a bad import.
            if data == nil { data = try? readValidated(lastGoodURL) }
            self.error = data == nil ? "尚无有效数据。请从电脑导入已备份的 Air 记录。" : "新导入文件无效；仍显示上次已核验的数据。"
            complicationReady = data.map(ComplicationSnapshot.publish) ?? false
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

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("独立手表 · 本地估算")
                            .font(.caption2).foregroundStyle(.secondary)
                        heartRatePanel(now: now)
                        if let data = store.data {
                            let level = StandaloneCurve.level(data, at: now)
                            let last = data.doses.filter { $0.at <= now }.max { $0.at < $1.at }
                            Text(String(format: "%.2f 倍", level))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(.mint)
                            CurvePlot(points: StandaloneCurve.points(data, now: now), now: now)
                                .frame(height: 100)
                            if let last {
                                Text("上次服药：\(last.at.formatted(.dateTime.month().day().hour().minute()))")
                                    .font(.caption2)
                            }
                            Text("数据截至 \(data.sourceCapturedAt.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                            if now.timeIntervalSince(data.sourceCapturedAt) > 2 * 3600 {
                                Text("快照超过 2 小时：此后新增服药不会自动出现，请勿当作最新记录。")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Text("参数：达峰 \(data.peakHours.formatted()) 小时 · 半衰期 \(data.halfLifeHours.formatted()) 小时")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.largeTitle).foregroundStyle(.mint)
                        }
                        if let error = store.error { Text(error).font(.caption2).foregroundStyle(.orange) }
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
            .navigationTitle("药时 · 独立")
            .onAppear { heartRate.refresh() }
            .onChange(of: scenePhase) { _, next in
                if next == .active { heartRate.refresh() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                if scenePhase == .active { heartRate.refresh() }
            }
        }
    }

    @ViewBuilder
    private func heartRatePanel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("心率 · 最近测量")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                if let reading = heartRate.latest {
                    Text("\(reading.bpm) 次/分")
                        .font(.headline).monospacedDigit().foregroundStyle(.red)
                } else {
                    Text("—").font(.headline)
                }
            }
            if let reading = heartRate.latest {
                Text("测于 \(reading.measuredAt.formatted(.dateTime.hour().minute()))\(now.timeIntervalSince(reading.measuredAt) > 10 * 60 ? " · 超过 10 分钟" : "")")
                    .font(.system(size: 10))
                    .foregroundStyle(now.timeIntervalSince(reading.measuredAt) > 10 * 60 ? .orange : .secondary)
            }
            Text("近 60 分钟平均：\(heartRate.averageLastHour.map { "\($0) 次/分" } ?? "暂无数据")")
                .font(.caption2)
            if !heartRate.message.isEmpty {
                Text(heartRate.message).font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("允许读取心率") { heartRate.requestAccess() }
                Button("刷新心率") { heartRate.refresh() }
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            Text("心率由手表测量，非持续实时值。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(6)
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
        }
    }
}
