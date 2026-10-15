import SwiftUI
import WidgetKit

private struct CurveEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchCurveSharedStore.Snapshot?
}

private struct CurveProvider: TimelineProvider {
    func placeholder(in context: Context) -> CurveEntry { CurveEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (CurveEntry) -> Void) {
        completion(CurveEntry(date: .now, snapshot: WatchCurveSharedStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CurveEntry>) -> Void) {
        let now = Date()
        let snapshot = WatchCurveSharedStore.read()
        guard let snapshot else {
            completion(Timeline(entries: [CurveEntry(date: now, snapshot: nil)],
                                policy: .after(now.addingTimeInterval(3600))))
            return
        }
        // A timeline is a forecast from the last synced phone record. WidgetKit decides
        // when entries are displayed; the watch app asks for a reload on each new snapshot.
        let stop = min(snapshot.curve.end, now.addingTimeInterval(12 * 3600))
        var dates = [now]
        var next = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 900) * 900)
        while next <= stop {
            if next > now { dates.append(next) }
            next = next.addingTimeInterval(900)
        }
        if snapshot.curve.end > now && snapshot.curve.end <= now.addingTimeInterval(12 * 3600) {
            dates.append(snapshot.curve.end.addingTimeInterval(1))
        }
        let entries = dates.sorted().map { CurveEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(max(now.addingTimeInterval(1800), stop))))
    }
}

private struct CurveComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CurveEntry

    private var level: Double? {
        guard let snapshot = entry.snapshot else { return nil }
        return WatchCurveMath.level(in: snapshot.curve, at: entry.date)
    }

    private var number: String {
        guard let level else { return "—" }
        return level < 0.01 ? "<0.01" : String(format: "%.2f", level)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("药时 · 模型估算").font(.system(size: 10, weight: .medium))
                        Spacer(minLength: 2)
                        Text(level == nil ? "待同步" : "\(number)×")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    if let snapshot = entry.snapshot, level != nil {
                        MiniCurve(curve: snapshot.curve, at: entry.date)
                            .frame(height: 25)
                        Text("同步 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened)) · 预测")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    } else {
                        Text("打开手表药时并连接手机")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            case .accessoryInline:
                Text(level == nil ? "药时待同步" : "药时估算 \(number)×")
            case .accessoryCircular, .accessoryCorner:
                VStack(spacing: 0) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 11))
                    Text(number).font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.65)
                    Text(level == nil ? "待同步" : "估算×")
                        .font(.system(size: 8))
                }
            default:
                Text(level == nil ? "药时待同步" : "药时 \(number)×")
            }
        }
        .foregroundStyle(.mint)
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(level.map { "药时，当前模型估算相对浓度 \(String(format: "%.2f", $0)) 倍，非血液检测结果" }
                            ?? "药时曲线待同步")
    }
}

private struct MiniCurve: View {
    let curve: WatchCurveSnapshot
    let at: Date

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let start = max(curve.start, at.addingTimeInterval(-4 * 3600))
                let end = min(curve.end, at.addingTimeInterval(8 * 3600))
                let span = end.timeIntervalSince(start)
                guard span > 0, curve.upperLevel > 0 else { return }
                let points = curve.samples.filter { $0.at >= start && $0.at <= end }
                guard points.count >= 2 else { return }
                var line = Path()
                for (index, sample) in points.enumerated() {
                    let x = size.width * sample.at.timeIntervalSince(start) / span
                    let y = size.height * (1 - min(1, max(0, sample.level / curve.upperLevel)))
                    if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(line, with: .color(.mint), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                let x = size.width * at.timeIntervalSince(start) / span
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
            }
        }
    }
}

@main
struct WatchCurveComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchCurveSharedStore.complicationKind, provider: CurveProvider()) { entry in
            CurveComplicationView(entry: entry)
        }
        .configurationDisplayName("药时浓度曲线")
        .description("显示手机同步的模型估算值与预测曲线。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}
