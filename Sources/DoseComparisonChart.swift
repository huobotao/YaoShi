import SwiftUI

struct DoseComparisonChart: View {
    var model: DoseComparisonModel
    var height: CGFloat = 176
    var onAssumedAtChange: ((Date) -> Void)?
    var selectedTime: Date?
    var onSelectedTimeChange: ((Date) -> Void)?

    private enum Interaction: String, CaseIterable {
        case inspect = "查数值", pan = "移动时间", assumed = "移动模拟时间"
    }
    @State private var interaction = Interaction.inspect
    @State private var selectedDate: Date?
    @State private var center: Date
    @State private var duration: TimeInterval
    @State private var initialDuration: TimeInterval
    @State private var dragStartCenter: Date?
    @State private var pinchStartDuration: TimeInterval = 1
    @State private var pinchAnchor: Date?
    @State private var isPinching = false

    init(model: DoseComparisonModel, height: CGFloat = 176,
         onAssumedAtChange: ((Date) -> Void)? = nil,
         selectedTime: Date? = nil, onSelectedTimeChange: ((Date) -> Void)? = nil) {
        self.model = model
        self.height = height
        self.onAssumedAtChange = onAssumedAtChange
        self.selectedTime = selectedTime
        self.onSelectedTimeChange = onSelectedTimeChange
        let span = max(60, model.end.timeIntervalSince(model.start))
        _center = State(initialValue: model.start.addingTimeInterval(span / 2))
        _duration = State(initialValue: span)
        _initialDuration = State(initialValue: span)
    }

    private var visibleRange: ClosedRange<Date> {
        center.addingTimeInterval(-duration / 2)...center.addingTimeInterval(duration / 2)
    }
    private var zoomScale: Double { initialDuration / duration }
    private var selected: Date { selectedDate ?? model.assumedAt }
    private var selectionText: String {
        let levels = model.levels(at: selected)
        return "\(Fmt.mdhm(selected))，不加新剂 \(DoseCurveModel.levelText(levels.withoutDose))，模拟后 \(DoseCurveModel.levelText(levels.withDose))"
    }

    var body: some View {
        let range = visibleRange
        VStack(alignment: .leading, spacing: 10) {
            Picker("图表操作", selection: $interaction) {
                ForEach(Interaction.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            zoomControls
            VStack(alignment: .leading, spacing: 4) {
                Text("查值 · \(Fmt.mdhm(selected))")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                let levels = model.levels(at: selected)
                HStack {
                    Text("不加新剂 \(DoseCurveModel.levelText(levels.withoutDose))").foregroundStyle(YS.teal)
                    Spacer(minLength: 4)
                    Text("模拟后 \(DoseCurveModel.levelText(levels.withDose))").foregroundStyle(YS.amber)
                }.font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("simulationSelectedCoordinates")
            GeometryReader { geometry in
                plot(width: geometry.size.width, height: geometry.size.height, range: range)
                    .clipped()
            }
            .frame(height: height)
            HStack {
                axisLabel(range.lowerBound)
                Spacer()
                axisLabel(center)
                Spacer()
                axisLabel(range.upperBound)
            }
            .font(.system(size: 10)).foregroundStyle(YS.dim)
            HStack(spacing: 14) {
                legend("不加新一剂", color: YS.teal)
                legend("模拟服药后", color: YS.amber)
            }
            Text("模拟服药 · \(Fmt.mdhm(model.assumedAt))")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(YS.amber)
            Text(interaction == .assumed
                 ? "单指拖动橙色模拟时间线；也可点选未来时刻。仅改变假想服药时间。"
                 : interaction == .pan
                 ? "单指左右移动时间，可继续查看更早或更晚；双指缩放。"
                 : "单指拖动查看时间与两条曲线的倍数；双指缩放。")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
            Text("统一纵轴 · 白色虚线为现在，橙色线为模拟服药；短竖线为实际记录。非实测血药浓度。")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
        }
        .onAppear {
            if let selectedTime {
                selectedDate = selectedTime
                if !visibleRange.contains(selectedTime) { center = selectedTime }
            }
        }
        .onChange(of: selected) { _, value in onSelectedTimeChange?(value) }
        .onChange(of: selectedTime) { _, value in
            guard let value, value != selected else { return }
            selectedDate = value
            if !visibleRange.contains(value) { center = value }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 12) {
            Button { setDuration(duration * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("缩小模拟曲线")
            Text(zoomScale < 0.1 || zoomScale > 1000 ? String(format: "%.2g×", zoomScale) : String(format: "%.1f×", zoomScale))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(YS.dim).frame(minWidth: 42)
            Button { setDuration(duration / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("放大模拟曲线").disabled(duration <= 60)
            Spacer(minLength: 0)
            Button("定位模拟") { center = model.assumedAt }
                .font(.system(size: 11, weight: .semibold))
            Button("重置") {
                let span = max(60, model.end.timeIntervalSince(model.start))
                duration = span
                initialDuration = span
                center = model.start.addingTimeInterval(span / 2)
                selectedDate = nil
            }.font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain).font(.system(size: 17, weight: .semibold)).foregroundStyle(YS.teal)
    }

    private func setDuration(_ value: TimeInterval) {
        guard value.isFinite, value > 0 else { return }
        duration = min(CurveTimeViewport.maximumDuration, max(CurveTimeViewport.minimumDuration, value))
    }

    private func date(at point: CGFloat, width: CGFloat, range: ClosedRange<Date>) -> Date {
        let fraction = min(1, max(0, Double((point - 5) / max(1, width - 10))))
        return range.lowerBound.addingTimeInterval(fraction * range.upperBound.timeIntervalSince(range.lowerBound))
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(YS.text)
        }
    }

    private func axisLabel(_ date: Date) -> some View {
        VStack(spacing: 1) {
            if duration > 180 * 86400 { Text(date.formatted(.dateTime.year())) }
            Text(Fmt.md(date))
            Text(Fmt.hm(date)).monospacedDigit()
        }
    }

    private func plot(width w: CGFloat, height h: CGFloat, range: ClosedRange<Date>) -> some View {
        let samples = model.samples(in: range)
        let upper = max(1.15, (samples.map(\.withDose).max() ?? 0) * 1.18)
        let x: (Date) -> CGFloat = { 5 + (w - 10) * CGFloat($0.timeIntervalSince(range.lowerBound) / duration) }
        let y: (Double) -> CGFloat = { h - 5 - (h - 36) * CGFloat($0 / upper) }
        let before = samples.filter { $0.at <= model.now }
        let after = samples.filter { $0.at >= model.now }

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 5, y: y(1)))
                path.addLine(to: CGPoint(x: w - 5, y: y(1)))
                path.move(to: CGPoint(x: 5, y: h - 5))
                path.addLine(to: CGPoint(x: w - 5, y: h - 5))
            }.stroke(YS.dim.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            Text("1.0").font(.system(size: 9)).foregroundStyle(YS.dim).position(x: 15, y: y(1) - 7)
            Text("0").font(.system(size: 9)).foregroundStyle(YS.dim).position(x: w - 7, y: h - 12)
            line(before, x: x, y: y, level: \.withoutDose)
                .stroke(YS.teal, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
            line(after, x: x, y: y, level: \.withoutDose)
                .stroke(YS.teal.opacity(0.9), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, dash: [5, 3]))
            line(before, x: x, y: y, level: \.withDose)
                .stroke(YS.amber.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            line(after, x: x, y: y, level: \.withDose)
                .stroke(YS.amber, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, dash: [5, 3]))
            ForEach(model.actualDoses.filter { range.contains($0.at) }) { dose in
                Path { path in
                    path.move(to: CGPoint(x: x(dose.at), y: h - 5))
                    path.addLine(to: CGPoint(x: x(dose.at), y: h - 18))
                }.stroke(YS.dim.opacity(0.45), lineWidth: 1.5)
            }
            if range.contains(model.now) {
                Path { path in
                    path.move(to: CGPoint(x: x(model.now), y: 28))
                    path.addLine(to: CGPoint(x: x(model.now), y: h - 5))
                }.stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text("现在").font(.system(size: 9, weight: .semibold)).foregroundStyle(YS.text)
                    .position(x: min(w - 17, max(17, x(model.now))), y: 21)
            }
            if range.contains(model.assumedAt) {
                Path { path in
                    path.move(to: CGPoint(x: x(model.assumedAt), y: 30))
                    path.addLine(to: CGPoint(x: x(model.assumedAt), y: h - 5))
                }.stroke(YS.amber.opacity(0.85), lineWidth: interaction == .assumed ? 3 : 1.5)
                Text("模拟 \(Fmt.hm(model.assumedAt))").font(.system(size: 10, weight: .bold)).foregroundStyle(YS.amber)
                    .position(x: min(w - 45, max(45, x(model.assumedAt))), y: 7)
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(YS.amber)
                    .position(x: x(model.assumedAt), y: h - 17)
            }
            if range.contains(selected) {
                let levels = model.levels(at: selected)
                Path { path in
                    path.move(to: CGPoint(x: x(selected), y: 32))
                    path.addLine(to: CGPoint(x: x(selected), y: h - 5))
                }.stroke(YS.teal, lineWidth: 1)
                selectedGuide(value: levels.withoutDose, color: YS.teal, x: x(selected), y: y(levels.withoutDose), width: w)
                selectedGuide(value: levels.withDose, color: YS.amber, x: x(selected), y: y(levels.withDose), width: w)
            }
            CurveTouchSurface(
                onTouch: { point, translation, state in
                    guard !isPinching else { return }
                    switch interaction {
                    case .inspect:
                        selectedDate = date(at: point.x, width: w, range: visibleRange)
                    case .pan:
                        if state == .began { dragStartCenter = center }
                        let offset = -Double(translation / max(1, w - 10)) * duration
                        if let start = dragStartCenter, offset.isFinite {
                            let next = start.addingTimeInterval(offset)
                            if next.timeIntervalSinceReferenceDate.isFinite {
                                center = Date(timeIntervalSinceReferenceDate: CurveTimeViewport.boundedOffset(next.timeIntervalSinceReferenceDate))
                                if onSelectedTimeChange != nil { selectedDate = center }
                            }
                        }
                        if state == .ended { dragStartCenter = nil }
                    case .assumed:
                        let next = max(model.now, date(at: point.x, width: w, range: visibleRange))
                        onAssumedAtChange?(next)
                        selectedDate = next
                    }
                },
                onPinch: { scale, location, state in
                    if state == .began {
                        isPinching = true
                        pinchStartDuration = duration
                        pinchAnchor = date(at: location.x, width: w, range: visibleRange)
                    }
                    if state == .began || state == .changed, scale.isFinite, scale > 0 {
                        setDuration(pinchStartDuration / Double(scale))
                        if let anchor = pinchAnchor {
                            let fraction = min(1, max(0, Double((location.x - 5) / max(1, w - 10))))
                            let next = anchor.addingTimeInterval((0.5 - fraction) * duration)
                            if next.timeIntervalSinceReferenceDate.isFinite {
                                center = Date(timeIntervalSinceReferenceDate: CurveTimeViewport.boundedOffset(next.timeIntervalSinceReferenceDate))
                            }
                        }
                    }
                    if state == .ended || state == .cancelled || state == .failed {
                        isPinching = false
                        pinchAnchor = nil
                    }
                },
                onAccessibilityStep: { direction in
                    let delta = Double(direction) * max(60, duration / 20)
                    switch interaction {
                    case .inspect: selectedDate = selected.addingTimeInterval(delta)
                    case .pan:
                        center = center.addingTimeInterval(delta)
                        if onSelectedTimeChange != nil { selectedDate = center }
                    case .assumed: onAssumedAtChange?(max(model.now, model.assumedAt.addingTimeInterval(delta)))
                    }
                },
                accessibilityValue: selectionText
            ).frame(width: w, height: h)
        }
    }

    private func selectedGuide(value: Double, color: Color, x: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 5, y: y))
                path.addLine(to: CGPoint(x: width - 5, y: y))
            }.stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Circle().fill(color).frame(width: 8, height: 8).position(x: x, y: y)
            Text(DoseCurveModel.levelText(value))
                .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                .padding(.horizontal, 4).background(YS.card2, in: RoundedRectangle(cornerRadius: 3))
                .position(x: color == YS.teal ? 38 : width - 38, y: max(40, y - 9))
        }.allowsHitTesting(false)
    }

    private func line(_ samples: [DoseComparisonModel.Sample], x: (Date) -> CGFloat,
                      y: (Double) -> CGFloat, level: KeyPath<DoseComparisonModel.Sample, Double>) -> Path {
        Path { path in
            guard let first = samples.first else { return }
            path.move(to: CGPoint(x: x(first.at), y: y(first[keyPath: level])))
            for sample in samples.dropFirst() {
                path.addLine(to: CGPoint(x: x(sample.at), y: y(sample[keyPath: level])))
            }
        }
    }
}
