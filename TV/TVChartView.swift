import SwiftUI

/// A remote-friendly, read-only canvas. Only the viewport and cursor are editable.
struct TVChartView: View {
    let doses: [Dose]
    let curve: PlasmaCurveConfiguration
    let now: Date
    @State private var offset: Double = 0
    @State private var zoom: Double = 1
    @State private var cursor: Date?
    @State private var inspecting = false
    @FocusState private var chartFocused: Bool

    private var range: ClosedRange<Date> {
        CurveTimeViewport.range(baseStart: now.addingTimeInterval(-86400),
                                baseEnd: now.addingTimeInterval(43200), zoom: zoom, offset: offset)
    }
    private var model: DoseCurveModel { DoseCurveModel(doses: doses, now: now, curve: curve) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(inspecting ? "查值" : "现在").foregroundStyle(.secondary)
                Text(dateText(cursor ?? now)).monospacedDigit()
                Spacer()
                Text(DoseCurveModel.levelText(model.level(at: cursor ?? now)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).foregroundStyle(.cyan)
            }
            GeometryReader { geometry in
                let samples = model.samples(in: range)
                let upper = max(1.15, (samples.map(\.level).max() ?? 0) * 1.15)
                let width = geometry.size.width
                let height = geometry.size.height - 45
                Canvas { context, _ in
                    func x(_ date: Date) -> CGFloat {
                        CGFloat(date.timeIntervalSince(range.lowerBound) / range.upperBound.timeIntervalSince(range.lowerBound)) * width
                    }
                    func y(_ level: Double) -> CGFloat { height * (1 - CGFloat(level / upper)) }
                    for level in [0.0, 1.0, upper] {
                        let line = Path { p in p.move(to: CGPoint(x: 0, y: y(level))); p.addLine(to: CGPoint(x: width, y: y(level))) }
                        context.stroke(line, with: .color(.white.opacity(0.17)), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                        context.draw(Text(String(format: "%.2f×", level)).font(.system(size: 19)).foregroundColor(.gray), at: CGPoint(x: 4, y: max(14, y(level) - 14)), anchor: .leading)
                    }
                    var past = Path(), future = Path()
                    for (i, sample) in samples.enumerated() {
                        let point = CGPoint(x: x(sample.at), y: y(sample.level))
                        if sample.at <= now { if past.isEmpty { past.move(to: point) } else { past.addLine(to: point) } }
                        if sample.at >= now {
                            if future.isEmpty {
                                if i > 0 { let prev = samples[i - 1]; future.move(to: CGPoint(x: x(prev.at), y: y(prev.level))) }
                                else { future.move(to: point) }
                            }
                            future.addLine(to: point)
                        }
                    }
                    context.stroke(past, with: .color(.orange), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    context.stroke(future, with: .color(.orange), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 7]))
                    let selected = cursor ?? now
                    if range.contains(selected) {
                        let px = x(selected), py = y(model.level(at: selected))
                        let guides = Path { p in
                            p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: height))
                            p.move(to: CGPoint(x: 0, y: py)); p.addLine(to: CGPoint(x: width, y: py))
                        }
                        context.stroke(guides, with: .color(.cyan.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                        context.fill(Path(ellipseIn: CGRect(x: px - 7, y: py - 7, width: 14, height: 14)), with: .color(.cyan))
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack { Text(dateText(range.lowerBound)); Spacer(); Text(dateText(range.upperBound)) }
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(chartFocused ? Color.cyan.opacity(0.65) : .clear, lineWidth: 2))
            .focusable().focused($chartFocused)
            .onMoveCommand { direction in
                let span = range.upperBound.timeIntervalSince(range.lowerBound)
                switch direction {
                case .left, .right:
                    let sign: Double = direction == .left ? -1 : 1
                    if inspecting {
                        cursor = (cursor ?? now).addingTimeInterval(sign * span / 60)
                        if let cursor, !range.contains(cursor) { offset = CurveTimeViewport.boundedOffset(offset + sign * span / 3) }
                    } else { offset = CurveTimeViewport.boundedOffset(offset + sign * span / 4) }
                case .up: changeZoom(1.5)
                case .down: changeZoom(1 / 1.5)
                default: break
                }
            }
            HStack(spacing: 24) {
                Button(inspecting ? "切换为移动时间" : "切换为查数值") { inspecting.toggle(); if !inspecting { cursor = nil } }
                Button("缩小") { changeZoom(1 / 1.5) }
                Button("放大") { changeZoom(1.5) }
                Button("回到现在") { offset = 0; zoom = 1; cursor = nil }
                Button("操作曲线") { chartFocused = true }
            }.font(.system(size: 21))
            Text("聚焦曲线：左右移动或查值，上下缩放。实线为历史模型，虚线为未来模型。")
                .font(.system(size: 20)).foregroundStyle(.secondary)
        }
    }

    private func changeZoom(_ factor: Double) {
        zoom = CurveTimeViewport.resolvedZoom(zoom * factor, baseDuration: 129600)
    }
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"; return formatter.string(from: date)
    }
}
