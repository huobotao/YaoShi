import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

// MARK: - 配色（扩展里独立一份，避免依赖主 App 的 UI 文件）

private enum W {
    static let teal   = Color(red: 0.157, green: 0.796, blue: 0.761)
    static let amber  = Color(red: 1.000, green: 0.729, blue: 0.290)
    static let orange = Color(red: 0.976, green: 0.549, blue: 0.290)
    static let violet = Color(red: 0.639, green: 0.549, blue: 0.933)
    static let dim    = Color(red: 0.588, green: 0.635, blue: 0.729)

    static func color(_ p: DosePhase) -> Color {
        switch p {
        case .none:    return dim
        case .waiting: return teal.opacity(0.7)
        case .rising:  return teal
        case .peak:    return amber
        case .fading:  return orange
        case .tail:    return violet
        case .over:    return dim
        }
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let snap: SharedSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: SharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        let snap = SharedStore.load()
        var dates: [Date] = [now]
        // 未来 24 小时每半小时一个条目，够把药效阶段的变化走完
        for i in 1...48 { dates.append(now.addingTimeInterval(Double(i) * 1800)) }
        // 阶段分界点单独插进去，保证正好在那一刻切换
        if let last = snap?.status.lastDoseAt {
            for h in [DoseEngine.onsetStart, DoseEngine.peakStart, DoseEngine.peakEnd,
                      DoseEngine.fadeEnd, DoseEngine.effectEnd] {
                let t = last.addingTimeInterval(h * 3600)
                if t > now && t < now.addingTimeInterval(24 * 3600) { dates.append(t) }
            }
        }
        let entries = Set(dates).sorted().map { Entry(date: $0, snap: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(24 * 3600))))
    }
}

// MARK: - 计算

// 小组件自己按快照里最近几片药算叠加，这样 timeline 的每个未来时刻都算得准，
// 不用等主 App 醒来重算。快照来自旧版本时没有 recentDoses，退回只看最后一次。

private func stack(_ snap: SharedSnapshot?) -> [Dose] {
    guard let snap else { return [] }
    // An explicit empty array means records were cleared; only legacy snapshots
    // without the array may reconstruct a last dose.
    if let ticks = snap.recentDoses { return ticks.map(\.asDose) }
    guard let last = snap.status.lastDoseAt else { return [] }
    return [Dose(at: last, mg: snap.status.lastMg)]
}

private func phase(_ snap: SharedSnapshot?, at now: Date) -> DosePhase {
    guard let last = stack(snap).map(\.at).max() else { return .none }
    return DoseEngine.phase(hoursSinceDose: now.timeIntervalSince(last) / 3600)
}

/// 体内总药量（这一层可以相加）
private func plasma(_ snap: SharedSnapshot?, at now: Date) -> Double {
    DoseEngine.totalPlasma(stack(snap), at: now, curve: snap?.plasmaCurve ?? .standard)
}

/// 进度条用最近一次的剩余有效时间，不用药量——两者语义不同
private func remaining(_ snap: SharedSnapshot?, at now: Date) -> Double {
    guard let last = stack(snap).map(\.at).max() else { return 0 }
    return DoseEngine.remaining(hoursSinceDose: now.timeIntervalSince(last) / 3600)
}

/// 最近一次预计退干净的时刻
private func fadeOut(_ snap: SharedSnapshot?) -> Date? {
    guard let last = stack(snap).map(\.at).max() else { return nil }
    return last.addingTimeInterval(DoseEngine.effectEnd * 3600)
}

private func gapText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds)), h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24) 天 \(h % 24) 小时 \(m) 分" }
    return h == 0 ? "\(m) 分" : "\(h) 小时 \(m) 分"
}

// MARK: - 视图

struct YaoShiWidgetView: View {
    var entry: Entry
    @Environment(\.widgetFamily) var family

    private var p: DosePhase { phase(entry.snap, at: entry.date) }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:    circular
            case .accessoryRectangular: rectangular
            case .accessoryInline:      inline
            case .systemMedium:         medium
            default:                    small
            }
        }
        .widgetURL(URL(string: "yaoshi-21011r5://take"))
    }

    // 主屏小号
    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: p.symbol).font(.system(size: 11))
                Text(p == .none ? "药时" : p.label).font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(W.color(p))

            if let last = entry.snap?.status.lastDoseAt {
                Text("距上次服药").font(.system(size: 9)).foregroundStyle(W.dim)
                Text(last, style: .timer)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(W.color(p))
                bar
                Text("\(Fmt2.hm(last)) 服 \(entry.snap?.status.lastMg ?? 0) 毫克")
                    .font(.system(size: 9)).foregroundStyle(W.dim)
            } else {
                Spacer()
                Text("还没记过").font(.system(size: 15, weight: .bold))
                Text("点一下就记一次").font(.system(size: 10)).foregroundStyle(W.dim)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    // 主屏中号
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: p.symbol).font(.system(size: 11))
                    Text(p == .none ? "药时" : p.label).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(W.color(p))
                if let last = entry.snap?.status.lastDoseAt {
                    Text("距上次服药").font(.system(size: 9)).foregroundStyle(W.dim)
                    Text(last, style: .timer)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(W.color(p))
                    Text("\(Fmt2.hm(last)) 服 \(entry.snap?.status.lastMg ?? 0) 毫克")
                        .font(.system(size: 10)).foregroundStyle(W.dim)
                } else {
                    Text("还没有服药记录").font(.system(size: 15, weight: .bold))
                    Text("点一下就记下此刻").font(.system(size: 10)).foregroundStyle(W.dim)
                }
                Spacer(minLength: 0)
                footer
            }
            VStack(alignment: .leading, spacing: 6) {
                if let last = entry.snap?.status.lastDoseAt, last <= entry.date {
                    Text("相对浓度估算 " + DoseCurveModel.levelText(plasma(entry.snap, at: entry.date)))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(W.dim)
                }
                curve
                if let end = fadeOut(entry.snap), p != .none, p != .over {
                    Text("参考时段至 \(Fmt2.hm(end))")
                        .font(.system(size: 9)).foregroundStyle(W.dim)
                }
                bar
            }
            .frame(maxWidth: .infinity)
        }
    }

    // 锁屏矩形
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let last = entry.snap?.status.lastDoseAt {
                HStack(spacing: 4) {
                    Image(systemName: p.symbol).font(.system(size: 10))
                    Text(p.label).font(.system(size: 11, weight: .semibold))
                }
                Text(last, style: .timer)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text("\(Fmt2.hm(last)) 服 \(entry.snap?.status.lastMg ?? 0) 毫克")
                    .font(.system(size: 10))
            } else {
                Text("药时").font(.system(size: 13, weight: .bold))
                Text("还没有服药记录").font(.system(size: 11))
            }
        }
    }

    // 锁屏圆形
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.snap?.status.lastDoseAt != nil {
                Gauge(value: remaining(entry.snap, at: entry.date)) {
                    Image(systemName: "pills.fill").font(.system(size: 9))
                } currentValueLabel: {
                    Text("\(Int(entry.date.timeIntervalSince(entry.snap!.status.lastDoseAt!) / 3600))")
                        .font(.system(size: 15, weight: .bold)).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                Image(systemName: "pills").font(.system(size: 18))
            }
        }
    }

    // 锁屏单行
    private var inline: some View {
        if let last = entry.snap?.status.lastDoseAt {
            Label("\(p.label) · \(gapText(entry.date.timeIntervalSince(last)))", systemImage: "pills.fill")
        } else {
            Label("药时 · 还没记过", systemImage: "pills")
        }
    }

    // 共用零件

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(W.color(p))
                    .frame(width: g.size.width * CGFloat(remaining(entry.snap, at: entry.date)))
            }
        }
        .frame(height: 5)
    }

    private var curve: some View {
        let model = DoseCurveModel(doses: stack(entry.snap), now: entry.date,
                                   curve: entry.snap?.plasmaCurve ?? .standard)
        return VStack(spacing: 2) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let x: (Date) -> CGFloat = { 3 + (w - 6) * CGFloat(model.fraction(at: $0)) }
                let y: (Double) -> CGFloat = { h - 3 - (h - 13) * CGFloat($0 / model.upperLevel) }
                let nowX = x(model.now)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 3, y: y(1)))
                        path.addLine(to: CGPoint(x: w - 3, y: y(1)))
                    }.stroke(W.dim.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    ForEach([false, true], id: \.self) { isFuture in
                        let samples = model.samples.filter { isFuture ? $0.at >= model.now : $0.at <= model.now }
                        Path { path in
                            guard let first = samples.first else { return }
                            path.move(to: CGPoint(x: x(first.at), y: y(first.level)))
                            for sample in samples.dropFirst() {
                                path.addLine(to: CGPoint(x: x(sample.at), y: y(sample.level)))
                            }
                        }.stroke(W.color(p), style: StrokeStyle(lineWidth: 1.6, dash: isFuture ? [3, 2] : []))
                    }
                    ForEach(model.visibleDoses) { dose in
                        Path { path in
                            path.move(to: CGPoint(x: x(dose.at), y: h - 3))
                            path.addLine(to: CGPoint(x: x(dose.at), y: h - 13))
                        }.stroke(W.dim.opacity(0.5), lineWidth: 1)
                    }
                    Path { path in
                        path.move(to: CGPoint(x: nowX, y: 10))
                        path.addLine(to: CGPoint(x: nowX, y: h - 3))
                    }.stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    Text("现在").font(.system(size: 7)).foregroundStyle(.white)
                        .position(x: min(w - 10, max(10, nowX)), y: 4)
                    Circle().fill(.white).frame(width: 6, height: 6)
                        .position(x: nowX, y: y(model.currentLevel))
                }
            }.frame(height: 52)
            HStack {
                Text(Fmt2.mdhm(model.start))
                Spacer(minLength: 0)
                Text(Fmt2.mdhm(model.end))
            }.font(.system(size: 7)).foregroundStyle(W.dim)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let s = entry.snap {
            if s.skippedToday {
                Text("今天标记为不吃").font(.system(size: 9)).foregroundStyle(W.violet)
            } else if s.status.takenToday > 0 {
                let n = s.status.takenToday
                let mg = s.status.todayMg ?? 0
                Text(n > 1 ? "今天 \(n) 次 共 \(mg) 毫克" : "今天已服 \(n) 次")
                    .font(.system(size: 9)).foregroundStyle(W.dim)
            } else {
                Text("按需记录").font(.system(size: 9)).foregroundStyle(W.dim)
            }
        }
    }
}

enum Fmt2 {
    static func mdhm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: d)
    }
    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

// MARK: - 小组件定义

struct YaoShiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "YaoShiWidget", provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                YaoShiWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                YaoShiWidgetView(entry: entry).padding()
            }
        }
        .configurationDisplayName("药时")
        .description("距离上次服药多久、现在处在药效的哪一段。点一下直接记一次。")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - 实时活动（锁屏 + 灵动岛）

@available(iOS 16.2, *)
struct DoseLiveActivity: Widget {
    private func ratio(_ st: DoseAttributes.ContentState, stale: Bool) -> String {
        guard let value = st.concentrationRatio, value.isFinite else { return "—×" }
        let number = value < 0.01 ? "<0.01×" : String(format: "%.2f×", value)
        return (stale ? "旧" : "") + number
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DoseAttributes.self) { context in
            summary(context.state, stale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(W.teal)
        } dynamicIsland: { context in
            let st = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            trendArrow(st, isStale: stale, compact: true)
                            Text("相对浓度 · 估算").font(.system(size: 10)).foregroundStyle(W.dim)
                        }
                        Text(ratio(st, stale: stale))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundStyle(W.teal)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    peak(st, stale: stale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    details(st, stale: stale)
                }
            } compactLeading: {
                if st.predictedPeakTimerInterval != nil {
                    // Keep concentration and the native countdown on separate sides.
                    // The optional arrow is the first item dropped when space is tight.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 2) {
                            trendArrow(st, isStale: stale, compact: true)
                            compactRatio(st, stale: stale)
                        }.fixedSize(horizontal: true, vertical: false)
                        compactRatio(st, stale: stale)
                    }
                } else {
                    trendArrow(st, isStale: stale)
                }
            } compactTrailing: {
                if let interval = st.predictedPeakTimerInterval {
                    Text(timerInterval: interval, countsDown: true, showsHours: true)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 56, alignment: .trailing)
                        .foregroundStyle(W.teal)
                        .accessibilityLabel("预计达峰倒计时")
                } else {
                    compactRatio(st, stale: stale)
                }
            } minimal: {
                Text(ratio(st, stale: stale))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(W.teal)
            }
            .widgetURL(URL(string: "yaoshi-21011r5://dashboard"))
            .keylineTint(W.teal)
        }
    }

    private func compactRatio(_ st: DoseAttributes.ContentState, stale: Bool) -> some View {
        Text(ratio(st, stale: stale))
            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(W.teal)
            .accessibilityLabel(stale ? "上次浓度估算 " + ratio(st, stale: true) : "估算相对浓度 " + ratio(st, stale: false))
    }

    @ViewBuilder
    private func trendArrow(_ st: DoseAttributes.ContentState, isStale: Bool, compact: Bool = false) -> some View {
        if let slope = st.plasmaSlopePerHour, slope.isFinite, !isStale {
            Image(systemName: "arrow.right")
                .font(.system(size: compact ? 11 : 15, weight: .bold))
                .rotationEffect(.degrees(PlasmaTrend.angleDegrees(slope: slope)))
                .frame(width: compact ? 14 : 22, height: 22)
                .foregroundStyle(W.teal)
                .accessibilityLabel(abs(slope) < 1e-9 ? "浓度平稳" : slope > 0 ? "浓度上升" : "浓度下降")
                .accessibilityValue(String(format: "每小时变化 %+.3f 倍", slope))
        } else {
            Image(systemName: "questionmark")
                .font(.system(size: compact ? 10 : 13, weight: .semibold))
                .frame(width: compact ? 14 : 22, height: 22)
                .foregroundStyle(W.dim)
                .accessibilityLabel("趋势等待更新")
        }
    }

    @ViewBuilder
    private func peak(_ st: DoseAttributes.ContentState, stale: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let interval = st.predictedPeakTimerInterval {
                Text(stale ? "上次预计距峰" : "预计距峰").font(.system(size: 10)).foregroundStyle(W.dim)
                Text(timerInterval: interval, countsDown: true)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit().frame(maxWidth: 96)
                Text("约 " + Fmt2.hm(interval.upperBound)).font(.system(size: 9)).foregroundStyle(W.dim)
            } else {
                Text(stale ? "估算待刷新" : "暂无后续峰值")
                    .font(.system(size: 11)).foregroundStyle(W.dim)
            }
        }
    }

    private func details(_ st: DoseAttributes.ContentState, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let last = st.lastDoseAt {
                HStack(spacing: 4) {
                    Text("上次 \(st.lastMg) mg · 已过")
                    Text(last, style: .timer).monospacedDigit()
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(W.dim)
            }
            HStack {
                Text(stale ? "\(Fmt2.hm(st.refreshedAt)) 时估算 · 点右侧刷新" : "1× = 单次 50 mg 模型峰值")
                    .font(.system(size: 9)).foregroundStyle(W.dim)
                Spacer(minLength: 4)
                Button(intent: RefreshDoseActivityIntent()) {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(W.teal)
                .accessibilityLabel("按本机记录刷新浓度估算")
            }
        }
    }

    private func summary(_ st: DoseAttributes.ContentState, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        trendArrow(st, isStale: stale)
                        Text("药时 · 相对浓度估算").font(.system(size: 11)).foregroundStyle(W.dim)
                    }
                    Text(ratio(st, stale: stale))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(W.teal)
                }
                Spacer()
                peak(st, stale: stale)
            }
            details(st, stale: stale)
        }
    }
}

// MARK: - 入口

@main
struct YaoShiWidgetBundle: WidgetBundle {
    var body: some Widget {
        YaoShiWidget()
        if #available(iOS 16.2, *) { DoseLiveActivity() }
    }
}
