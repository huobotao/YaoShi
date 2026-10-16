import SwiftUI

struct HeartRateCurvePlot: View {
    let readings: [HeartRateStore.Reading]
    let window: HeartRateStore.HistoryWindow
    let now: Date

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 28, y: 7,
                             width: max(1, size.width - 33),
                             height: max(1, size.height - 25))
            let start = now.addingTimeInterval(-window.duration)
            let visible = readings
                .filter { $0.measuredAt >= start && $0.measuredAt <= now }
                .sorted { $0.measuredAt < $1.measuredAt }

            let minimum = visible.map(\.bpm).min() ?? 60
            let maximum = visible.map(\.bpm).max() ?? 100
            let lower = max(30, floor((minimum - 10) / 10) * 10)
            let upper = min(220, max(lower + 20, ceil((maximum + 10) / 10) * 10))
            let bpmSpan = max(20, upper - lower)

            func xPosition(_ date: Date) -> CGFloat {
                let fraction = date.timeIntervalSince(start) / window.duration
                return plot.minX + CGFloat(min(1, max(0, fraction))) * plot.width
            }
            func yPosition(_ bpm: Double) -> CGFloat {
                let fraction = (bpm - lower) / bpmSpan
                return plot.maxY - CGFloat(min(1, max(0, fraction))) * plot.height
            }
            for tick in 0...2 {
                let fraction = CGFloat(tick) / 2
                let y = plot.maxY - fraction * plot.height
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
                let value = upper - Double(tick) / 2 * bpmSpan
                let bpmLabel = context.resolve(
                    Text("\(Int(value))")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                )
                context.draw(bpmLabel, at: CGPoint(x: 12, y: y))
            }

            for tick in 0...2 {
                let fraction = Double(tick) / 2
                let label = tick == 2 ? "现在" : axisLabel(secondsAgo: window.duration * (1 - fraction))
                let x = plot.minX + CGFloat(fraction) * plot.width
                let labelX = tick == 0 ? x + 12 : (tick == 2 ? x - 12 : x)
                let timeLabel = context.resolve(
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                )
                context.draw(timeLabel, at: CGPoint(x: labelX, y: size.height - 5))
            }

            guard !visible.isEmpty else {
                let text = context.resolve(
                    Text("此范围内没有心率样本")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                )
                context.draw(text, at: CGPoint(x: plot.midX, y: plot.midY))
                return
            }

            var line = Path()
            var previous: HeartRateStore.Reading?
            for reading in visible {
                let point = CGPoint(x: xPosition(reading.measuredAt), y: yPosition(reading.bpm))
                if let previous,
                   reading.measuredAt.timeIntervalSince(previous.measuredAt) <= 5 * 60 {
                    line.addLine(to: point)
                } else {
                    line.move(to: point)
                }
                previous = reading
            }
            context.stroke(line, with: .color(.red), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            for reading in visible {
                let point = CGPoint(x: xPosition(reading.measuredAt), y: yPosition(reading.bpm))
                let dot = Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
                context.fill(dot, with: .color(.red))
            }
        }
        .accessibilityLabel("过去\(window.label)的心率曲线")
        .accessibilityHint("每个点是健康记录中的一次心率样本；空白表示这段时间没有样本")
    }

    private func axisLabel(secondsAgo: TimeInterval) -> String {
        let minutes = max(1, Int((secondsAgo / 60).rounded()))
        if minutes >= 60 && minutes.isMultiple(of: 60) {
            return "-\(minutes / 60)时"
        }
        return "-\(minutes)分"
    }
}
