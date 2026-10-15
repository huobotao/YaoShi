import SwiftUI

/// This Watch-only companion reads the paired Air R4's dose summaries. The current
/// phone build does not transmit its adjustable curve settings or food state.
/// Show those limitations beside every estimate instead of implying an exact
/// match with the iPhone.
struct WatchCurveView: View {
    @EnvironmentObject private var link: YaoShiWatchLink

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                let snapshot = link.state.snapshot
                let doses = link.state.records.filter { $0.at <= now }
                let points = WatchCurveModel.points(doses: doses, now: now)
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("相对浓度 · 模型估算")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(snapshot == nil ? "—" : String(format: "%.2f 倍", WatchCurveModel.level(doses: doses, at: now)))
                            .font(.system(size: 29, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(.mint)
                        if snapshot != nil {
                            WatchCurvePlot(points: points, now: now)
                                .frame(height: 105)
                        }
                        HStack {
                            Text("过去 18 小时")
                            Spacer()
                            Text("未来 8 小时")
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                        if let latest = doses.max(by: { $0.at < $1.at }) {
                            Text("最近服药：\(latest.at.formatted(.dateTime.month().day().hour().minute())) · \(latest.mg) 毫克")
                                .font(.caption2)
                        } else {
                            Text("尚未收到服药记录，请在配对的 iPhone Air 打开药时曲线·R4。")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let receivedAt = link.state.snapshot?.generatedAt {
                            Text("手机记录同步于 \(receivedAt.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if WatchCurveModel.isStale(generatedAt: snapshot?.generatedAt, now: now) {
                            Text("手机记录超过 2 小时未同步，可能缺少新服药；请先刷新核对。")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        Text("按达峰 3.8 小时、半衰期 10.5 小时估算；手机修改参数、进食状态或尚未同步的新记录不会自动反映，可能与手机数值不同。仅显示最近 7 天的已同步记录。")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Text("仅供记录参考，不是血液检测或用药建议。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let issue = link.issue {
                            Text(issue).font(.caption2).foregroundStyle(.orange)
                        }
                        Button("刷新手机记录") { link.refresh() }
                            .font(.caption2)
                    }
                    .padding(.horizontal, 2).padding(.bottom, 12)
                }
                .background(Color.black)
            }
            .navigationTitle("药时 · 浓度")
        }
    }
}

private struct WatchCurvePlot: View {
    let points: [WatchCurveModel.Point]
    let now: Date

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2, let first = points.first, let last = points.last else { return }
            let span = max(1, last.at.timeIntervalSince(first.at))
            let top: CGFloat = 6
            let bottom = size.height - 4
            let ceiling = max(1.15, (points.map(\.level).max() ?? 0) * 1.12)
            func position(_ p: WatchCurveModel.Point) -> CGPoint {
                CGPoint(x: CGFloat(p.at.timeIntervalSince(first.at) / span) * size.width,
                        y: bottom - CGFloat(p.level / ceiling) * (bottom - top))
            }
            var history = Path()
            var future = Path()
            for (index, point) in points.enumerated() {
                let p = position(point)
                if index == 0 { history.move(to: p) }
                else if point.at <= now { history.addLine(to: p) }
                else if future.isEmpty {
                    future.move(to: position(points[index - 1]))
                    future.addLine(to: p)
                } else { future.addLine(to: p) }
            }
            context.stroke(history, with: .color(.mint), lineWidth: 2)
            context.stroke(future, with: .color(.mint.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let x = CGFloat(now.timeIntervalSince(first.at) / span) * size.width
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: top))
            marker.addLine(to: CGPoint(x: x, y: bottom))
            context.stroke(marker, with: .color(.white.opacity(0.6)), lineWidth: 0.7)
        }
        .accessibilityLabel("药时相对浓度估算曲线")
    }
}
