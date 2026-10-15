import SwiftUI
import WidgetKit

private struct CurveEntry: TimelineEntry {
    let date: Date
    let data: StandaloneImport?
}

private struct CurveProvider: TimelineProvider {
    func placeholder(in context: Context) -> CurveEntry {
        CurveEntry(date: .now, data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CurveEntry) -> Void) {
        completion(CurveEntry(date: .now, data: ComplicationSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurveEntry>) -> Void) {
        let now = Date()
        let data = ComplicationSnapshot.read(now: now)
        // The curve is deterministic between doses. Future entries update the estimate
        // without keeping the watch app in the foreground. WidgetKit may defer updates.
        let entries = (0...24).map { offset in
            CurveEntry(date: now.addingTimeInterval(Double(offset) * 15 * 60), data: data)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
    }
}

private struct CurveComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CurveEntry

    private var levelText: String {
        guard let data = entry.data else { return "—" }
        return String(format: "%.2f", StandaloneCurve.level(data, at: entry.date))
    }

    private var isStale: Bool {
        guard let data = entry.data else { return true }
        return entry.date.timeIntervalSince(data.sourceCapturedAt) > 2 * 3600
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("药时")
                        Text("\(levelText)×")
                            .fontWeight(.bold)
                        if isStale { Text("旧记录").font(.system(size: 8)) }
                    }
                    .font(.system(size: 12, design: .rounded))
                    .lineLimit(1)
                    if let data = entry.data {
                        MiniCurve(data: data, now: entry.date)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("打开药时导入记录")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(levelText)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(isStale ? "旧·倍" : "药时·倍")
                        .font(.system(size: 8))
                }
            case .accessoryCorner:
                Text("\(levelText)×")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .widgetLabel(isStale ? "药时·旧记录" : "药时·估算")
            case .accessoryInline:
                Text(isStale ? "药时 \(levelText)×·旧记录" : "药时 \(levelText)×")
            default:
                Text("药时 \(levelText)×")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(isStale ? "药时旧记录，估算浓度 \(levelText) 倍" : "药时估算浓度 \(levelText) 倍")
    }
}

private struct MiniCurve: View {
    let data: StandaloneImport
    let now: Date

    var body: some View {
        Canvas { context, size in
            let start = now.addingTimeInterval(-6 * 3600)
            let end = now.addingTimeInterval(8 * 3600)
            let points = (0...56).map { index -> (Date, Double) in
                let at = start.addingTimeInterval(Double(index) * end.timeIntervalSince(start) / 56)
                return (at, StandaloneCurve.level(data, at: at))
            }
            let ceiling = max(1, (points.map(\.1).max() ?? 0) * 1.1)
            func xy(_ value: (Date, Double)) -> CGPoint {
                CGPoint(x: size.width * value.0.timeIntervalSince(start) / end.timeIntervalSince(start),
                        y: size.height * (1 - value.1 / ceiling))
            }
            var past = Path()
            var future = Path()
            for (index, value) in points.enumerated() {
                if index == 0 { past.move(to: xy(value)); continue }
                if value.0 <= now {
                    past.addLine(to: xy(value))
                } else {
                    if future.isEmpty { future.move(to: xy(points[index - 1])) }
                    future.addLine(to: xy(value))
                }
            }
            context.stroke(past, with: .color(.mint), lineWidth: 2)
            context.stroke(future, with: .color(.mint.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let marker = CGPoint(x: size.width * 6 / 14,
                                 y: size.height * (1 - StandaloneCurve.level(data, at: now) / ceiling))
            context.fill(Path(ellipseIn: CGRect(x: marker.x - 2, y: marker.y - 2,
                                                width: 4, height: 4)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}

@main
struct YaoShiCurveComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationSnapshot.widgetKind, provider: CurveProvider()) { entry in
            CurveComplicationView(entry: entry)
        }
        .configurationDisplayName("药时浓度与曲线")
        .description("在表盘显示药物浓度估算；矩形位置显示曲线。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}
