import SwiftUI
import UIKit

// MARK: - 配色（只做深色）

enum YS {
    static let bg      = Color(red: 0.043, green: 0.059, blue: 0.102)   // 页面底
    static let card    = Color(red: 0.082, green: 0.106, blue: 0.169)   // 卡片
    static let card2   = Color(red: 0.114, green: 0.145, blue: 0.220)   // 卡片里的次级块
    static let line    = Color.white.opacity(0.08)
    static let text    = Color(red: 0.925, green: 0.941, blue: 0.976)
    static let dim     = Color(red: 0.588, green: 0.635, blue: 0.729)

    static let teal    = Color(red: 0.157, green: 0.796, blue: 0.761)   // 主色
    static let amber   = Color(red: 1.000, green: 0.729, blue: 0.290)   // 高峰
    static let orange  = Color(red: 0.976, green: 0.549, blue: 0.290)   // 衰退
    static let violet  = Color(red: 0.639, green: 0.549, blue: 0.933)   // 尾声
    static let red     = Color(red: 0.976, green: 0.365, blue: 0.353)   // 警告

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

// MARK: - 通用卡片

struct Card<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 12))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(YS.dim)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YS.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(YS.line))
    }
}

// MARK: - 时间格式

enum Fmt {
    /// 「3 小时 42 分」
    static func gap(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h == 0 { return "\(m) 分钟" }
        return "\(h) 小时 \(m) 分"
    }

    /// 跨天持续累计；没有每日目标或到期含义。
    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时 \(remainder) 分" }
        if hours > 0 { return "\(hours) 小时 \(remainder) 分" }
        return "\(remainder) 分钟"
    }

    /// 「3 小时 42 分」的两段式，供大字显示
    static func gapParts(_ seconds: TimeInterval) -> (big: String, unit: String, small: String, smallUnit: String) {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h == 0 { return ("\(m)", "分钟", "", "") }
        return ("\(h)", "小时", "\(m)", "分")
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    static func md(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M月d日"; return f.string(from: d)
    }

    static func mdhm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f.string(from: d)
    }

    /// 小数小时 → 「8:30」
    static func hour(_ h: Double) -> String {
        let hh = Int(h), mm = Int((h - Double(hh)) * 60)
        return String(format: "%d:%02d", hh, mm)
    }
}

// MARK: - 星级评分

struct Stars: View {
    @Binding var value: Int
    var max: Int = 5
    var tint: Color = YS.amber
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...max, id: \.self) { i in
                Image(systemName: i <= value ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= value ? tint : YS.dim.opacity(0.4))
                    .onTapGesture { value = (value == i) ? 0 : i }
            }
        }
    }
}

// MARK: - 药效强度条

struct LevelBar: View {
    var level: Double
    var phase: DosePhase
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(YS.color(phase))
                    .frame(width: g.size.width * CGFloat(min(1, Swift.max(0, level))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 相对浓度模型曲线

/// 单指查数值，双指缩放；选择时间和读数始终来自同一模型时刻。
struct DoseCurve: View {
    var model: DoseCurveModel
    var phase: DosePhase
    var height: CGFloat = 132
    var annotations: [EffectLog] = []
    var lifeEvents: [LifeEvent] = []
    var expanded: Bool = false
    var episode: DoseEpisode? = nil
    var showDecayMilestones = false
    var onExpand: (() -> Void)? = nil
    var onEditNote: ((EffectLog) -> Void)? = nil
    var selectedTime: Date? = nil
    var onSelectedTimeChange: ((Date) -> Void)? = nil

    @State private var zoomScale = 1.0
    @State private var centerOffsetSeconds = 0.0
    @State private var pinchStartZoom = 1.0
    @State private var pinchAnchorDate: Date?
    @State private var dragStartOffset = 0.0
    @State private var isPinching = false
    @State private var selectedDate: Date?
    @State private var isMovingTime = false
    @State private var selectedAnnotationID: UUID?

    // The initial window stays near now; the viewport can travel beyond it in either direction.
    private var baseStart: Date { episode?.start?.at.addingTimeInterval(-3600) ?? model.start }
    private var baseEnd: Date { model.end }
    private var baseDuration: Double { max(60, baseEnd.timeIntervalSince(baseStart)) }
    private var maximumZoom: Double { baseDuration / CurveTimeViewport.minimumDuration }
    private var minimumZoom: Double { baseDuration / CurveTimeViewport.maximumDuration }
    private var resolvedZoom: Double {
        CurveTimeViewport.resolvedZoom(zoomScale, baseDuration: baseDuration)
    }
    private var visibleDuration: Double { baseDuration / resolvedZoom }
    private var baseCenter: Date { baseStart.addingTimeInterval(baseDuration / 2) }
    private var visibleRange: ClosedRange<Date> {
        CurveTimeViewport.range(baseStart: baseStart, baseEnd: baseEnd,
                                zoom: resolvedZoom, offset: centerOffsetSeconds)
    }

    private var numberedDoses: [Dose] {
        episode?.doses ?? model.historyDoses.filter { $0.id != model.hypotheticalDoseID }.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at
        }
    }

    private var doseTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(episode == nil ? "服药时间与间隔" : "这一轮 · 服药时间与间隔")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(YS.text)
            if numberedDoses.isEmpty {
                Text("尚未选择这一轮起点，可在首页的首次服药卡片中选择。")
                    .font(.system(size: 12)).foregroundStyle(YS.dim)
            }
            ForEach(Array(numberedDoses.enumerated()), id: \.element.id) { index, dose in
                Button {
                    selectedDate = dose.at
                    let center = visibleRange.lowerBound.addingTimeInterval(visibleDuration / 2)
                    if !visibleRange.contains(dose.at) {
                        centerOffsetSeconds += dose.at.timeIntervalSince(center)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .frame(minWidth: 24, minHeight: 24)
                            .background(YS.teal.opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("第 \(index + 1) 次 · \(Fmt.mdhm(dose.at))")
                                .foregroundStyle(YS.text)
                            Text(index == 0 ? (episode == nil ? "首条记录" : "这一轮首次服药")
                                 : "距上次 \(Fmt.gap(dose.at.timeIntervalSince(numberedDoses[index - 1].at)))")
                                .foregroundStyle(YS.teal)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("curveDoseRow-\(index + 1)")
            }
        }
        .padding(12)
        .background(YS.card2, in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedAnnotation: EffectLog? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    private var inspectionDate: Date? {
        selectedDate.map { min(visibleRange.upperBound, max(visibleRange.lowerBound, $0)) }
    }

    private func date(at x: CGFloat, width: CGFloat, in range: ClosedRange<Date>) -> Date {
        let fraction = min(1, max(0, Double((x - 5) / max(1, width - 10))))
        return range.lowerBound.addingTimeInterval(fraction * range.upperBound.timeIntervalSince(range.lowerBound))
    }

    var body: some View {
        let range = visibleRange
        let readoutDate = inspectionDate ?? model.now
        let readoutLevel = inspectionDate.map { model.level(at: $0) } ?? model.currentLevel
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(inspectionDate == nil ? "现在" : (readoutDate > model.now ? "预测" : "查值")) · \(Fmt.mdhm(readoutDate))")
                Spacer(minLength: 6)
                Text(DoseCurveModel.levelText(readoutLevel)).monospacedDigit()
                if let onExpand, !expanded {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YS.teal)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏放大曲线")
                    .accessibilityIdentifier("expandDoseCurve")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(YS.text)
            .accessibilityIdentifier("curveCurrentValue")

            zoomControls

            GeometryReader { g in
                let samples = model.samples(in: range, count: expanded ? 480 : 240)
                plot(width: g.size.width, height: g.size.height, range: range, samples: samples)
            }
            .frame(height: height)

            Text("横轴：时间 · 纵轴：相对浓度（倍）")
                .font(.system(size: 10)).foregroundStyle(YS.dim)

            HStack(alignment: .top, spacing: 2) {
                axisLabel(range.lowerBound, alignment: .leading)
                Spacer(minLength: 0)
                axisLabel(range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2), alignment: .center)
                Spacer(minLength: 0)
                axisLabel(range.upperBound, alignment: .trailing)
            }
            if showDecayMilestones {
                DecayMilestoneView(doses: model.historyDoses, now: model.now, curve: model.curve)
            }
            doseTimeline
            HStack(spacing: 4) {
                if !annotations.isEmpty {
                    Image(systemName: "text.bubble.fill").foregroundStyle(YS.amber)
                    Text("感受笔记标记")
                }
                Image(systemName: "hand.pinch.fill").foregroundStyle(YS.teal)
                Text(isMovingTime ? "单指移动时间 · 双指缩放" : "单指滑动查数值 · 双指缩放")
                Spacer(minLength: 0)
                if expanded { Text(zoomLabel).monospacedDigit() }
            }
            .font(.system(size: 10))
            .foregroundStyle(YS.dim)
            if let note = selectedAnnotation {
                selectedNoteCard(note)
            }
            if !lifeEvents.isEmpty {
                Text("淡紫背景＝已配对的睡觉与醒来记录。")
                    .font(.system(size: 10)).foregroundStyle(YS.dim)
            }
            Text("1.0 = 单次 50 毫克模型峰值；非实测血药浓度。")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
            Text(model.hypotheticalDoseID == nil
                 ? "圆点＝实际服药时刻；编号对应下方明细，点击明细可定位。现在右侧虚线＝未来估算。"
                 : "橙色竖线＝假设这一剂；现在右侧虚线＝未来估算。")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
        }
        .onAppear {
            if let selectedTime { selectExternalTime(selectedTime) }
        }
        .onChange(of: inspectionDate) { _, value in
            onSelectedTimeChange?(value ?? model.now)
        }
        .onChange(of: selectedTime) { _, value in
            guard let value, value != inspectionDate else { return }
            selectExternalTime(value)
        }
    }

    private func selectExternalTime(_ value: Date) {
        selectedDate = value
        if !visibleRange.contains(value) {
            centerOffsetSeconds = value.timeIntervalSince(baseCenter)
        }
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("曲线手势", selection: $isMovingTime) {
                Text("查数值").tag(false)
                Text("移动时间").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("curveInteractionMode")
            HStack(spacing: 6) {
                Button { setZoom(resolvedZoom / 1.5) } label: {
                    Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 36)
                }
                .disabled(resolvedZoom <= minimumZoom)
                .accessibilityLabel("缩小曲线")
                Text(zoomLabel).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(YS.dim).frame(minWidth: 48)
                Button { setZoom(resolvedZoom * 1.5) } label: {
                    Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 36)
                }
                .disabled(resolvedZoom >= maximumZoom)
                .accessibilityLabel("放大曲线")
                Spacer(minLength: 0)
                Button("回到现在") { resetZoom() }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(YS.teal)
        }
    }

    private var zoomLabel: String {
        resolvedZoom >= 1_000_000 || resolvedZoom < 0.1
            ? String(format: "%.2e×", resolvedZoom)
            : String(format: "%.1f×", resolvedZoom)
    }

    private func setZoom(_ requested: Double) {
        let center = inspectionDate ?? visibleRange.lowerBound.addingTimeInterval(visibleDuration / 2)
        zoomScale = CurveTimeViewport.resolvedZoom(requested, baseDuration: baseDuration)
        centerOffsetSeconds = center.timeIntervalSince(baseCenter)
    }

    private func resetZoom() {
        zoomScale = 1
        centerOffsetSeconds = 0
        selectedDate = onSelectedTimeChange == nil ? nil : model.now
        isMovingTime = false
    }

    private func selectedNoteCard(_ note: EffectLog) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundStyle(YS.amber)
                Text("感受笔记 · \(Fmt.mdhm(note.at))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(YS.text)
                Spacer()
                if let onEditNote {
                    Button("编辑") { onEditNote(note) }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(YS.teal)
                }
                Button { selectedAnnotationID = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YS.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭笔记")
            }
            Text(note.note).font(.system(size: 13)).foregroundStyle(YS.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(YS.card2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func axisLabel(_ date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(Fmt.md(date))
            Text(Fmt.hm(date)).monospacedDigit()
        }
        .font(.system(size: 10)).foregroundStyle(YS.dim)
    }

    private func plot(width w: CGFloat, height h: CGFloat, range: ClosedRange<Date>,
                      samples: [DoseCurveModel.Sample]) -> some View {
        let span = max(0.001, range.upperBound.timeIntervalSince(range.lowerBound))
        let x: (Date) -> CGFloat = { 5 + (w - 10) * CGFloat($0.timeIntervalSince(range.lowerBound) / span) }
        let yMax = max(model.upperLevel, max(1.15, (samples.map(\.level).max() ?? 0) * 1.12))
        let y: (Double) -> CGFloat = { h - 5 - (h - 38) * CGFloat($0 / yMax) }
        let past = samples.filter { $0.at <= model.now }
        let future = samples.filter { $0.at >= model.now }
        let nowIsVisible = model.now >= range.lowerBound && model.now <= range.upperBound
        let nowX = nowIsVisible ? x(model.now) : CGFloat.nan
        let currentY = y(model.currentLevel)
        let baselineY = y(1)
        let visibleDoses = model.historyDoses.filter { $0.at >= range.lowerBound && $0.at <= range.upperBound }
        let visibleNumbered = numberedDoses.filter { range.contains($0.at) }
        let badgeColumns = max(1, Int((w - 10) / 28))
        let badgeCount = min(badgeColumns, visibleNumbered.count)
        let visibleNotes = annotations.filter { !$0.note.isEmpty && $0.at >= range.lowerBound && $0.at <= range.upperBound }
        let sleepIntervals = LifeTimeline(events: lifeEvents, now: model.now).sleeps.filter {
            $0.wake.at > range.lowerBound && $0.sleep.at < range.upperBound
        }

        return ZStack(alignment: .topLeading) {
            ForEach(sleepIntervals, id: \.sleep.id) { interval in
                let left = x(max(range.lowerBound, interval.sleep.at))
                let right = x(min(range.upperBound, interval.wake.at))
                Rectangle().fill(YS.violet.opacity(0.09))
                    .frame(width: max(0, right - left), height: max(0, h - 23))
                    .position(x: (left + right) / 2, y: 18 + (h - 23) / 2)
                if right - left > 50 {
                    Text("睡眠").font(.system(size: 9)).foregroundStyle(YS.violet.opacity(0.8))
                        .position(x: (left + right) / 2, y: h - 34)
                }
            }
            // 统一纵轴参照：低值也不会因为自动缩放看起来很高。
            Path { p in
                p.move(to: CGPoint(x: 5, y: baselineY))
                p.addLine(to: CGPoint(x: w - 5, y: baselineY))
            }
            .stroke(YS.dim.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            Text("1.0").font(.system(size: 9)).foregroundStyle(YS.dim)
                .position(x: 15, y: baselineY - 7)
            Path { p in
                p.move(to: CGPoint(x: 5, y: h - 5))
                p.addLine(to: CGPoint(x: w - 5, y: h - 5))
            }.stroke(YS.line, lineWidth: 1)
            Text("0").font(.system(size: 9)).foregroundStyle(YS.dim)
                .position(x: w - 5, y: h - 12)

            Path { p in
                guard let first = past.first else { return }
                p.move(to: CGPoint(x: x(first.at), y: h - 5))
                for sample in past { p.addLine(to: CGPoint(x: x(sample.at), y: y(sample.level))) }
                if let last = past.last { p.addLine(to: CGPoint(x: x(last.at), y: h - 5)) }
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [YS.color(phase).opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
            line(past, x: x, y: y)
                .stroke(YS.color(phase), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            line(future, x: x, y: y)
                .stroke(YS.color(phase).opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))

            ForEach(visibleDoses) { dose in
                let markerColor = dose.id == model.hypotheticalDoseID ? YS.amber : YS.teal
                let pointY = y(model.level(at: dose.at))
                Path { p in
                    p.move(to: CGPoint(x: x(dose.at), y: h - 5))
                    p.addLine(to: CGPoint(x: x(dose.at), y: pointY))
                }
                .stroke(markerColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Circle().fill(markerColor).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(YS.card, lineWidth: 1))
                    .position(x: x(dose.at), y: pointY)
                if let index = numberedDoses.firstIndex(where: { $0.id == dose.id }),
                   let visibleIndex = visibleNumbered.firstIndex(where: { $0.id == dose.id }) {
                    let badgeX = 5 + (w - 10) * (CGFloat(visibleIndex % badgeColumns) + 0.5) / CGFloat(max(1, badgeCount))
                    let badgeY = CGFloat(29 + (visibleIndex / badgeColumns) * 20)
                    Path { p in
                        p.move(to: CGPoint(x: badgeX, y: badgeY + 9))
                        p.addLine(to: CGPoint(x: x(dose.at), y: pointY))
                    }
                    .stroke(markerColor.opacity(0.3), lineWidth: 0.7)
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(markerColor)
                        .frame(width: 20, height: 18)
                        .background(YS.card2, in: Capsule())
                        .position(x: badgeX, y: badgeY)
                        .allowsHitTesting(false)
                }
            }
            if nowIsVisible {
                Path { p in
                    p.move(to: CGPoint(x: nowX, y: 18))
                    p.addLine(to: CGPoint(x: nowX, y: h - 5))
                }
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if inspectionDate == nil {
                    Text("现在").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(YS.text)
                        .position(x: min(w - 18, max(18, nowX)), y: 7)
                }
                Circle().fill(YS.card).frame(width: 11, height: 11)
                    .position(x: nowX, y: currentY)
                Circle().fill(.white).frame(width: 7, height: 7)
                    .position(x: nowX, y: currentY)
            }

            if let selected = inspectionDate {
                let selectedX = x(selected)
                let selectedLevel = model.level(at: selected)
                let selectedY = y(selectedLevel)
                let badgeWidth = min(156, max(1, w - 10))
                Path { p in
                    p.move(to: CGPoint(x: selectedX, y: 25))
                    p.addLine(to: CGPoint(x: selectedX, y: h - 5))
                }
                .stroke(YS.teal, lineWidth: 1.5)
                Path { p in
                    p.move(to: CGPoint(x: 5, y: selectedY))
                    p.addLine(to: CGPoint(x: w - 5, y: selectedY))
                }
                .stroke(YS.teal.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Text("\(Fmt.hm(selected)) · \(DoseCurveModel.levelText(selectedLevel))")
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(YS.teal)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: badgeWidth, height: 23)
                    .background(YS.card2, in: Capsule())
                    .overlay(Capsule().stroke(YS.teal.opacity(0.5), lineWidth: 1))
                    .position(x: min(w - 5 - badgeWidth / 2, max(5 + badgeWidth / 2, selectedX)), y: 12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("curveSelectedCoordinates")
                Text(DoseCurveModel.levelText(selectedLevel))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(YS.teal)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(YS.card2, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .position(x: selectedX < w / 2 ? w - 38 : 38,
                              y: min(h - 13, max(35, selectedY)))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("curveSelectedLevel")
                Circle().fill(YS.card).frame(width: 13, height: 13)
                    .position(x: selectedX, y: selectedY)
                Circle().fill(YS.teal).frame(width: 9, height: 9)
                    .position(x: selectedX, y: selectedY)
            }

            CurveTouchSurface(
                onTouch: { point, translation, state in
                    guard !isPinching else { return }
                    if isMovingTime {
                        if state == .began {
                            let center = range.lowerBound.addingTimeInterval(span / 2)
                            dragStartOffset = center.timeIntervalSince(baseCenter)
                        }
                        let shift = -Double(translation / max(1, w - 10)) * visibleDuration
                        centerOffsetSeconds = CurveTimeViewport.boundedOffset(dragStartOffset + shift)
                        if onSelectedTimeChange != nil {
                            selectedDate = baseCenter.addingTimeInterval(centerOffsetSeconds)
                        }
                    } else {
                        selectedDate = date(at: point.x, width: w, in: visibleRange)
                    }
                },
                onPinch: { scale, location, state in
                    if state == .began {
                        isPinching = true
                        pinchStartZoom = resolvedZoom
                        pinchAnchorDate = date(at: location.x, width: w, in: visibleRange)
                    }
                    if state == .began || state == .changed, scale.isFinite, scale > 0 {
                        zoomScale = CurveTimeViewport.resolvedZoom(pinchStartZoom * Double(scale), baseDuration: baseDuration)
                        if let anchor = pinchAnchorDate {
                            let fraction = min(1, max(0, Double((location.x - 5) / max(1, w - 10))))
                            let center = anchor.addingTimeInterval((0.5 - fraction) * visibleDuration)
                            centerOffsetSeconds = CurveTimeViewport.boundedOffset(center.timeIntervalSince(baseCenter))
                        }
                    }
                    if state == .ended || state == .cancelled || state == .failed {
                        isPinching = false
                        pinchAnchorDate = nil
                    }
                },
                onAccessibilityStep: { direction in
                    let current = inspectionDate ?? min(range.upperBound, max(range.lowerBound, model.now))
                    selectedDate = min(range.upperBound, max(range.lowerBound,
                        current.addingTimeInterval(Double(direction) * max(60, span / 20))))
                },
                accessibilityValue: "\(Fmt.mdhm(inspectionDate ?? model.now))，\(DoseCurveModel.levelText(model.level(at: inspectionDate ?? model.now)))"
            )
            .frame(width: w, height: h)

            ForEach(visibleNotes) { note in
                let markerY = annotationY(for: note, in: visibleNotes, width: w, range: range)
                    + (inspectionDate == nil ? 0 : 18)
                let pointY = y(model.level(at: note.at))
                Path { p in
                    p.move(to: CGPoint(x: x(note.at), y: markerY + 9))
                    p.addLine(to: CGPoint(x: x(note.at), y: pointY))
                }
                .stroke(YS.amber.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Button {
                    selectedAnnotationID = note.id
                    selectedDate = note.at
                } label: {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YS.amber)
                        .frame(width: 27, height: 25)
                        .background(YS.card2, in: Capsule())
                        .overlay(Capsule().stroke(YS.amber.opacity(0.75), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .position(x: x(note.at), y: markerY)
                .accessibilityLabel("打开 \(Fmt.mdhm(note.at)) 的感受笔记")
            }
        }
    }

    private func annotationY(for note: EffectLog, in notes: [EffectLog], width: CGFloat,
                             range: ClosedRange<Date>) -> CGFloat {
        let span = max(0.001, range.upperBound.timeIntervalSince(range.lowerBound))
        let noteX = 5 + (width - 10) * CGFloat(note.at.timeIntervalSince(range.lowerBound) / span)
        let nearby = notes.filter { other in
            let otherX = 5 + (width - 10) * CGFloat(other.at.timeIntervalSince(range.lowerBound) / span)
            return abs(otherX - noteX) < 25
        }.sorted { $0.at < $1.at }
        let index = nearby.firstIndex(where: { $0.id == note.id }) ?? 0
        return min(70, 22 + CGFloat(index) * 14)
    }

    private func line(_ samples: [DoseCurveModel.Sample], x: (Date) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        Path { p in
            guard let first = samples.first else { return }
            p.move(to: CGPoint(x: x(first.at), y: y(first.level)))
            for sample in samples.dropFirst() { p.addLine(to: CGPoint(x: x(sample.at), y: y(sample.level))) }
        }
    }
}


/// A zero-delay, one-finger press owns chart touches before the enclosing ScrollView
/// starts scrolling. The separate pinch recognizer can run alongside it. Placing this
/// surface below note buttons keeps their taps out of these recognizers entirely.
struct CurveTouchSurface: UIViewRepresentable {
    var onTouch: (CGPoint, CGFloat, UIGestureRecognizer.State) -> Void
    var onPinch: (CGFloat, CGPoint, UIGestureRecognizer.State) -> Void
    var onAccessibilityStep: (Int) -> Void
    var accessibilityValue: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "相对浓度曲线"
        view.accessibilityHint = "上下轻扫调整查值时间；单指拖动查数值，双指缩放。"
        view.accessibilityIdentifier = "doseCurveTouchSurface"
        view.accessibilityTraits = [.adjustable]
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.touch(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.numberOfTouchesRequired = 1
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        context.coordinator.owner = self
        view.step = onAccessibilityStep
        view.accessibilityValue = accessibilityValue
    }

    final class TouchView: UIView {
        var step: ((Int) -> Void)?
        override func accessibilityIncrement() { step?(1) }
        override func accessibilityDecrement() { step?(-1) }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: CurveTouchSurface
        private var start = CGPoint.zero
        private var pinching = false
        private var suppressTouchUntilRelease = false
        init(_ owner: CurveTouchSurface) { self.owner = owner }

        @objc func touch(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { suppressTouchUntilRelease = false }
            guard !pinching, !suppressTouchUntilRelease, gesture.numberOfTouches <= 1 else { return }
            let point = gesture.location(in: gesture.view)
            if gesture.state == .began { start = point }
            if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
                owner.onTouch(point, point.x - start.x, gesture.state)
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                pinching = true
                suppressTouchUntilRelease = true
            }
            owner.onPinch(gesture.scale, gesture.location(in: gesture.view), gesture.state)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                pinching = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.view === otherGestureRecognizer.view &&
                (gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer)
        }
    }
}
