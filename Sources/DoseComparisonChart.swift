import SwiftUI

struct DoseComparisonModel {
    struct Sample {
        let at: Date
        let withoutDose: Double
        let withDose: Double
    }

    let now: Date
    let start: Date
    let end: Date
    let samples: [Sample]
    let actualDoses: [Dose]
    let assumedDose: Dose
    let upperLevel: Double
    let curve: PlasmaCurveConfiguration

    init(doses: [Dose], mg: Int, now: Date,
         curve: PlasmaCurveConfiguration = .standard) {
        self.now = now
        self.curve = curve
        let historyLimit = now.addingTimeInterval(-72 * 3600)
        let actual = doses.filter { $0.at <= now && $0.at.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.at < $1.at }
        let assumed = Dose(at: now, mg: mg)

        let earliest = actual.map(\.at).min()
        let proposedStart = earliest?.addingTimeInterval(-3600) ?? now.addingTimeInterval(-16 * 3600)
        let startDate = max(historyLimit, min(now.addingTimeInterval(-4 * 3600), proposedStart))
        let endDate = now.addingTimeInterval(12 * 3600)

        let sampleValues = Self.makeSamples(actual: actual, assumed: assumed, curve: curve,
                                            range: startDate...endDate, now: now, count: 240)
        actualDoses = actual
        assumedDose = assumed
        start = startDate
        end = endDate
        samples = sampleValues
        upperLevel = max(1.15, (sampleValues.map(\.withDose).max() ?? 0) * 1.12)
    }

    func levels(after interval: TimeInterval) -> (withoutDose: Double, withDose: Double) {
        let at = now.addingTimeInterval(interval)
        return (DoseEngine.totalPlasma(actualDoses, at: at, curve: curve),
                DoseEngine.totalPlasma(actualDoses + [assumedDose], at: at, curve: curve))
    }

    /// Zooming resamples both scenarios over the visible window using the same model.
    func samples(in range: ClosedRange<Date>, count: Int = 320) -> [Sample] {
        Self.makeSamples(actual: actualDoses, assumed: assumedDose, curve: curve,
                         range: range, now: now, count: count)
    }

    private static func makeSamples(actual: [Dose], assumed: Dose,
                                    curve: PlasmaCurveConfiguration,
                                    range: ClosedRange<Date>, now: Date, count: Int) -> [Sample] {
        let span = max(0.001, range.upperBound.timeIntervalSince(range.lowerBound))
        let steps = max(2, min(600, count))
        var dates = (0...steps).map {
            range.lowerBound.addingTimeInterval(span * Double($0) / Double(steps))
        }
        if range.contains(now) { dates.append(now) }
        let simulated = actual + [assumed]
        for dose in simulated {
            let absorption = dose.at.addingTimeInterval(curve.lag(for: dose.food) * 3600)
            let foodShift = dose.food == .withFood ? PlasmaCurveConfiguration.foodDelayHours : 0
            let peak = dose.at.addingTimeInterval((curve.peakTimeHours + foodShift) * 3600)
            dates.append(contentsOf: [dose.at, absorption, peak].filter { range.contains($0) })
        }
        return Array(Set(dates)).sorted().map { date in
            Sample(at: date,
                   withoutDose: DoseEngine.totalPlasma(actual, at: date, curve: curve),
                   withDose: DoseEngine.totalPlasma(simulated, at: date, curve: curve))
        }
    }

}

struct DoseComparisonChart: View {
    var model: DoseComparisonModel
    var height: CGFloat = 176

    @State private var labelWidth: CGFloat = 280
    @State private var selectedDoseID: UUID?
    @State private var zoomScale = 1.0
    @State private var centerOffsetSeconds = 0.0
    @State private var pinchStartZoom = 1.0
    @State private var pinchStartOffset = 0.0
    @State private var dragStartOffset = 0.0
    @State private var isPinching = false
    @State private var isDragging = false

    private var baseDuration: Double { max(0.001, model.end.timeIntervalSince(model.start)) }
    private var maximumZoom: Double { max(1, baseDuration / 0.001) }
    private var resolvedZoom: Double { min(maximumZoom, max(1, zoomScale.isFinite ? zoomScale : 1)) }
    private var visibleDuration: Double { max(0.001, baseDuration / resolvedZoom) }
    private var maximumOffset: Double { max(0, (baseDuration - visibleDuration) / 2) }
    private var resolvedOffset: Double { min(maximumOffset, max(-maximumOffset, centerOffsetSeconds)) }
    private var visibleRange: ClosedRange<Date> {
        let center = model.start.addingTimeInterval(baseDuration / 2 + resolvedOffset)
        return center.addingTimeInterval(-visibleDuration / 2)...center.addingTimeInterval(visibleDuration / 2)
    }

    var body: some View {
        let range = visibleRange
        VStack(alignment: .leading, spacing: 8) {
            zoomControls
            GeometryReader { geometry in
                plot(width: geometry.size.width, height: geometry.size.height, range: range)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                if !isPinching {
                                    isPinching = true
                                    pinchStartZoom = resolvedZoom
                                    pinchStartOffset = resolvedOffset
                                }
                                let magnification = Double(value)
                                guard magnification.isFinite, magnification > 0 else { return }
                                zoomScale = min(maximumZoom, max(1, pinchStartZoom * magnification))
                                centerOffsetSeconds = min(maximumOffset, max(-maximumOffset, pinchStartOffset))
                            }
                            .onEnded { _ in isPinching = false }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard !isPinching,
                                      abs(value.translation.width) > abs(value.translation.height) else { return }
                                if !isDragging {
                                    isDragging = true
                                    dragStartOffset = resolvedOffset
                                }
                                let shift = -Double(value.translation.width / max(1, geometry.size.width - 10)) * visibleDuration
                                centerOffsetSeconds = min(maximumOffset, max(-maximumOffset, dragStartOffset + shift))
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() })
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("同一纵轴下的模型估算曲线：不加新剂与模拟服药后。竖线标示现在；两条曲线都不是实测血药浓度。")

            GeometryReader { geometry in
                let labels = doseLabels(in: range, width: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(labels, id: \.dose.id) { label in
                        Button {
                            selectedDoseID = label.dose.id
                        } label: {
                            VStack(spacing: 1) {
                                Text(Fmt.md(label.dose.at))
                                Text(Fmt.hm(label.dose.at)).monospacedDigit()
                            }
                            .font(.system(size: 9, weight: selectedDoseID == label.dose.id ? .bold : .medium))
                            .foregroundStyle(selectedDoseID == label.dose.id ? YS.teal : YS.text)
                            .frame(width: 68, height: 30)
                            .background(YS.teal.opacity(selectedDoseID == label.dose.id ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("实际服药，\(Fmt.mdhm(label.dose.at))")
                        .position(x: label.x, y: CGFloat(label.lane) * 34 + 15)
                    }
                }
                .onAppear { labelWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in labelWidth = width }
            }
            .frame(height: CGFloat(doseLabelLaneCount(in: range)) * 34)
            if let dose = model.actualDoses.first(where: { $0.id == selectedDoseID }) {
                Text("实际服药 · \(Fmt.mdhm(dose.at))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(YS.teal)
            }
            Text("日期标签对应实际服药；模拟服药：\(Fmt.mdhm(model.now))")
                .font(.system(size: 10)).foregroundStyle(YS.dim)

            HStack(spacing: 14) {
                legend("不加新一剂", color: YS.teal)
                legend("模拟服药后", color: YS.amber)
            }
            HStack {
                axisLabel(range.lowerBound)
                Spacer()
                axisLabel(range.lowerBound.addingTimeInterval(visibleDuration / 2))
                Spacer()
                axisLabel(range.upperBound)
            }
            .font(.system(size: 10)).foregroundStyle(YS.dim)
            Text("双指缩放 · 放大后横向拖动 · 双击重置")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
            Text("统一纵轴；竖线为现在，右侧为未来模型估算。")
                .font(.system(size: 10)).foregroundStyle(YS.dim)
        }
    }

    private struct DoseLabel {
        let dose: Dose
        let x: CGFloat
        let lane: Int
    }

    private func doseLabels(in range: ClosedRange<Date>, width: CGFloat) -> [DoseLabel] {
        var laneEnds: [CGFloat] = []
        return model.actualDoses.filter { range.contains($0.at) }.map { dose in
            let position = 5 + (width - 10) * CGFloat(dose.at.timeIntervalSince(range.lowerBound) / visibleDuration)
            let x = min(max(34, position), max(34, width - 34))
            let lane = laneEnds.firstIndex(where: { $0 + 4 <= x - 34 }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(x + 34) }
            else { laneEnds[lane] = x + 34 }
            return DoseLabel(dose: dose, x: x, lane: lane)
        }
    }

    private func doseLabelLaneCount(in range: ClosedRange<Date>) -> Int {
        (doseLabels(in: range, width: labelWidth).map(\.lane).max() ?? -1) + 1
    }

    private var zoomControls: some View {
        HStack(spacing: 12) {
            Button { setZoom(resolvedZoom / 1.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel("缩小模拟曲线")
            .disabled(resolvedZoom <= 1)
            Text(resolvedZoom >= 1_000_000 ? String(format: "%.2e×", resolvedZoom) : String(format: "%.1f×", resolvedZoom))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(YS.dim).frame(minWidth: 56)
            Button { setZoom(resolvedZoom * 1.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("放大模拟曲线")
            .disabled(resolvedZoom >= maximumZoom)
            Button("重置") { resetZoom() }
                .font(.system(size: 11, weight: .semibold))
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(YS.teal)
    }

    private func setZoom(_ value: Double) {
        let offset = resolvedOffset
        zoomScale = min(maximumZoom, max(1, value.isFinite ? value : maximumZoom))
        centerOffsetSeconds = min(maximumOffset, max(-maximumOffset, offset))
    }

    private func resetZoom() {
        zoomScale = 1
        centerOffsetSeconds = 0
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(YS.text)
        }
    }

    private func axisLabel(_ date: Date) -> some View {
        VStack(spacing: 1) {
            Text(Fmt.md(date))
            Text(Fmt.hm(date)).monospacedDigit()
        }
    }

    private func plot(width w: CGFloat, height h: CGFloat, range: ClosedRange<Date>) -> some View {
        let x: (Date) -> CGFloat = { 5 + (w - 10) * CGFloat($0.timeIntervalSince(range.lowerBound) / visibleDuration) }
        let y: (Double) -> CGFloat = { h - 5 - (h - 16) * CGFloat($0 / model.upperLevel) }
        let samples = model.samples(in: range)
        let before = samples.filter { $0.at <= model.now }
        let after = samples.filter { $0.at >= model.now }
        let nowX = x(model.now)

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 5, y: y(1)))
                path.addLine(to: CGPoint(x: w - 5, y: y(1)))
                path.move(to: CGPoint(x: 5, y: h - 5))
                path.addLine(to: CGPoint(x: w - 5, y: h - 5))
            }
            .stroke(YS.dim.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
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
                    path.move(to: CGPoint(x: nowX, y: 10))
                    path.addLine(to: CGPoint(x: nowX, y: h - 5))
                }.stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text("现在").font(.system(size: 9, weight: .semibold)).foregroundStyle(YS.text)
                    .position(x: min(w - 17, max(17, nowX)), y: 6)
            }
        }
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
