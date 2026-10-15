import SwiftUI

/// The phone owns the concentration model; the watch only plots its sampled estimate.
struct WatchCurveView: View {
    @EnvironmentObject private var link: YaoShiWatchLink

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if let curve = link.state.snapshot?.curve, curve.samples.count >= 2 {
                            curveContent(curve, at: context.date)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.yellow)
                                Text("等待手机曲线").font(.headline)
                                Text("在配对的 iPhone 打开药时，即可同步浓度图表。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                        }
                        NavigationLink {
                            WatchDoseView()
                        } label: {
                            Label("服药记录与笔记", systemImage: "list.bullet")
                                .font(.caption)
                        }
                        Button("刷新手机数据") { link.refresh() }.font(.caption2)
                        if let issue = link.issue {
                            Text(issue).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 12)
                }
                .background(Color.black)
            }
            .navigationTitle("药时 · 浓度")
        }
    }

    @ViewBuilder private func curveContent(_ curve: WatchCurveSnapshot, at now: Date) -> some View {
        let current = WatchCurvePlot.level(in: curve.samples, at: now)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(current.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                .foregroundStyle(.yellow)
            Text("倍").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("相对浓度\n模型估算")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        WatchCurvePlot(curve: curve, now: now)
            .frame(height: 106)
            .accessibilityLabel("相对血药浓度曲线，黄色实线为历史估算，虚线为预测，青色圆点为服药时间")
            .accessibilityValue(current.map { "当前估算 \(String(format: "%.2f", $0)) 倍" } ?? "曲线已过期，需要同步")
        HStack {
            Text(curve.start.formatted(.dateTime.day().hour().minute()))
            Spacer(minLength: 4)
            Text(curve.end.formatted(.dateTime.day().hour().minute()))
        }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
        HStack(spacing: 8) {
            Text("● 服药").foregroundStyle(.mint)
            Text("┄ 预测").foregroundStyle(.yellow)
            Text("│ 现在").foregroundStyle(.white)
        }.font(.system(size: 10))
        if !link.state.pending.isEmpty {
            Text("有服药记录待同步，曲线尚未包含。")
                .font(.caption2).foregroundStyle(.orange)
        }
        if current == nil {
            Text("曲线时间范围已过，请打开手机刷新。")
                .font(.caption2).foregroundStyle(.orange)
        }
        if let generatedAt = link.state.snapshot?.generatedAt {
            Text("同步于 \(generatedAt.formatted(.dateTime.month().day().hour().minute()))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Text("估算值，非血液检测结果")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

private struct WatchCurvePlot: View {
    let curve: WatchCurveSnapshot
    let now: Date
    private let yellow = Color(red: 1, green: 0.75, blue: 0.29)

    static func level(in samples: [WatchCurveSample], at date: Date) -> Double? {
        guard let first = samples.first, let last = samples.last,
              date >= first.at, date <= last.at else { return nil }
        if date == first.at { return first.level }
        for (left, right) in zip(samples, samples.dropFirst()) where date >= left.at && date <= right.at {
            let span = right.at.timeIntervalSince(left.at)
            guard span > 0 else { continue }
            let fraction = date.timeIntervalSince(left.at) / span
            return left.level + (right.level - left.level) * fraction
        }
        return last.level
    }

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 4
            let top: CGFloat = 15
            let bottom = size.height - 4
            let width = max(1, size.width - 8)
            let height = max(1, bottom - top)
            let duration = curve.end.timeIntervalSince(curve.start)
            guard duration > 0, curve.upperLevel > 0 else { return }
            func point(_ at: Date, _ level: Double) -> CGPoint {
                CGPoint(x: left + CGFloat(at.timeIntervalSince(curve.start) / duration) * width,
                        y: bottom - CGFloat(max(0, min(curve.upperLevel, level)) / curve.upperLevel) * height)
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: left, y: bottom))
            baseline.addLine(to: CGPoint(x: left + width, y: bottom))
            context.stroke(baseline, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            if curve.upperLevel > 1 {
                var reference = Path()
                let y = point(curve.start, 1).y
                reference.move(to: CGPoint(x: left, y: y))
                reference.addLine(to: CGPoint(x: left + width, y: y))
                context.stroke(reference, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            }
            let currentLevel = Self.level(in: curve.samples, at: now)
            var history = curve.samples.filter { $0.at <= now }
            var forecast = curve.samples.filter { $0.at > now }
            if let currentLevel {
                let current = WatchCurveSample(at: now, level: currentLevel)
                history.append(current)
                forecast.insert(current, at: 0)
            }
            func line(_ samples: [WatchCurveSample]) -> Path {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let position = point(sample.at, sample.level)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                return path
            }
            context.stroke(line(history), with: .color(yellow), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            context.stroke(line(forecast), with: .color(yellow.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
            for dose in curve.doses where dose.at >= curve.start && dose.at <= min(now, curve.end) {
                let position = point(dose.at, dose.level)
                var guide = Path()
                guide.move(to: position)
                guide.addLine(to: CGPoint(x: position.x, y: bottom))
                context.stroke(guide, with: .color(.mint.opacity(0.35)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                context.fill(Path(ellipseIn: CGRect(x: position.x - 2.7, y: position.y - 2.7, width: 5.4, height: 5.4)), with: .color(.mint))
            }
            if let currentLevel {
                let position = point(now, currentLevel)
                var marker = Path()
                marker.move(to: CGPoint(x: position.x, y: top - 2))
                marker.addLine(to: CGPoint(x: position.x, y: bottom))
                context.stroke(marker, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.fill(Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)), with: .color(.white))
                context.draw(Text("现在").font(.system(size: 9)).foregroundColor(.white), at: CGPoint(x: min(size.width - 12, max(12, position.x)), y: 5))
            }
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
    }
}
