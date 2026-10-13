import SwiftUI

struct StatsView: View {
    @EnvironmentObject var store: Store
    @State private var range = 30

    private let ranges = [14, 30, 90]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    picker
                    punchCard
                    hourHistogram
                    intervalCard
                    reasonCard
                    sideCard
                    focusCard
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .background(YS.bg.ignoresSafeArea())
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var picker: some View {
        Picker("范围", selection: $range) {
            ForEach(ranges, id: \.self) { Text("近 \($0) 天").tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: 时间轴打卡图 —— 一眼看出每天几点吃的

    private var punchCard: some View {
        Card(title: "服药时刻分布", systemImage: "clock.badge.checkmark") {
            let cal = Calendar.current
            let now = Date()
            let doses = store.stats.recent(days: range)

            VStack(alignment: .leading, spacing: 6) {
                if doses.isEmpty {
                    Text("这段时间还没有记录").font(.system(size: 13)).foregroundStyle(YS.dim)
                } else {
                    GeometryReader { g in
                        let w = g.size.width - 26          // 左侧留给小时刻度
                        let h = g.size.height
                        ZStack(alignment: .topLeading) {
                            // 横向刻度线：0/6/12/18/24 点
                            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                                let y = h * CGFloat(Double(hour) / 24)
                                Path { p in
                                    p.move(to: CGPoint(x: 26, y: y)); p.addLine(to: CGPoint(x: 26 + w, y: y))
                                }
                                .stroke(YS.line, lineWidth: 1)
                                Text("\(hour)")
                                    .font(.system(size: 9)).foregroundStyle(YS.dim)
                                    .position(x: 12, y: max(6, min(h - 6, y)))
                            }
                            // 每一次服药一个点
                            ForEach(doses) { d in
                                let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: d.at),
                                                                 to: cal.startOfDay(for: now)).day ?? 0
                                let x = 26 + w * CGFloat(Double(range - 1 - daysAgo) / Double(max(1, range - 1)))
                                let y = h * CGFloat(d.hourOfDay / 24)
                                Circle()
                                    .fill(colorFor(d.hourOfDay))
                                    .frame(width: 7, height: 7)
                                    .position(x: x, y: y)
                            }
                        }
                    }
                    .frame(height: 190)
                    HStack {
                        Text("\(range) 天前").font(.system(size: 10)).foregroundStyle(YS.dim)
                        Spacer()
                        Text("今天").font(.system(size: 10)).foregroundStyle(YS.dim)
                    }
                    .padding(.leading, 26)
                    if let avg = store.stats.averageHour(days: range) {
                        Text("平均在 \(Fmt.hour(avg.mean)) 服药，波动 ±\(String(format: "%.1f", avg.sd)) 小时（\(avg.count) 次）")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                }
            }
        }
    }

    private func colorFor(_ h: Double) -> Color {
        switch h {
        case ..<9:  return YS.teal
        case ..<11: return YS.amber
        case ..<14: return YS.orange
        default:    return YS.red
        }
    }

    // MARK: 小时直方图

    private var hourHistogram: some View {
        Card(title: "都在几点吃", systemImage: "chart.bar.xaxis") {
            let bins = store.stats.hourHistogram(days: range)
            let maxV = max(1, bins.max() ?? 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(bins[h] > 0 ? colorFor(Double(h)) : Color.white.opacity(0.06))
                                .frame(height: max(2, CGFloat(bins[h]) / CGFloat(maxV) * 76))
                            if h % 6 == 0 {
                                Text("\(h)").font(.system(size: 8)).foregroundStyle(YS.dim)
                            } else {
                                Text(" ").font(.system(size: 8))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96, alignment: .bottom)
                if let peak = bins.enumerated().max(by: { $0.element < $1.element }), peak.element > 0 {
                    Text("最常在 \(peak.offset) 点这一小时吃（\(peak.element) 次）")
                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                }
            }
        }
    }

    // MARK: 间隔

    private var intervalCard: some View {
        Card(title: "两次之间隔多久", systemImage: "arrow.left.and.right") {
            let iv = store.stats.intervals(days: range)
            if iv.isEmpty {
                Text("还需要至少两次记录").font(.system(size: 13)).foregroundStyle(YS.dim)
            } else {
                let mean = iv.reduce(0, +) / Double(iv.count)
                let sorted = iv.sorted()
                let median = sorted[sorted.count / 2]
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.gap(mean * 3600)).font(.system(size: 19, weight: .bold))
                        Text("平均间隔").font(.system(size: 11)).foregroundStyle(YS.dim)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.gap(median * 3600)).font(.system(size: 19, weight: .bold))
                        Text("中位数").font(.system(size: 11)).foregroundStyle(YS.dim)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: 原因

    private var reasonCard: some View {
        let counts = store.stats.reasonCounts(days: range)
        return Group {
            if counts.isEmpty {
                Card(title: "为什么吃", systemImage: "questionmark.circle") {
                    Text("还没填过原因。记录时补一下，几周后就能看出规律。")
                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                }
            } else {
                Card(title: "为什么吃", systemImage: "questionmark.circle") {
                    let maxV = counts.first?.1 ?? 1
                    VStack(spacing: 8) {
                        ForEach(counts, id: \.0) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.0.symbol).font(.system(size: 11))
                                    .foregroundStyle(YS.teal).frame(width: 16)
                                Text(item.0.label).font(.system(size: 13)).frame(width: 62, alignment: .leading)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.06))
                                        Capsule().fill(YS.teal.opacity(0.7))
                                            .frame(width: g.size.width * CGFloat(item.1) / CGFloat(maxV))
                                    }
                                }
                                .frame(height: 12)
                                Text("\(item.1)").font(.system(size: 12)).monospacedDigit()
                                    .foregroundStyle(YS.dim).frame(width: 24, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 副作用

    private var sideCard: some View {
        let counts = store.stats.sideCounts(days: range)
        return Group {
            if !counts.isEmpty {
                Card(title: "出现过的反应", systemImage: "exclamationmark.bubble") {
                    let maxV = counts.first?.1 ?? 1
                    VStack(spacing: 8) {
                        ForEach(counts, id: \.0) { item in
                            HStack(spacing: 8) {
                                Text(item.0.label).font(.system(size: 13))
                                    .frame(width: 74, alignment: .leading)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.06))
                                        Capsule().fill(YS.orange.opacity(0.75))
                                            .frame(width: g.size.width * CGFloat(item.1) / CGFloat(maxV))
                                    }
                                }
                                .frame(height: 12)
                                Text("\(item.1)").font(.system(size: 12)).monospacedDigit()
                                    .foregroundStyle(YS.dim).frame(width: 24, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 效果与时间的关系

    private var focusCard: some View {
        let pts = store.stats.focusVsHours(days: range)
        return Group {
            if pts.count >= 3 {
                Card(title: "专注度 vs 服药后第几小时", systemImage: "scope") {
                    GeometryReader { g in
                        let w = g.size.width - 20, h = g.size.height - 16
                        ZStack(alignment: .topLeading) {
                            ForEach(1...5, id: \.self) { s in
                                let y = h - h * CGFloat(Double(s - 1) / 4)
                                Path { p in
                                    p.move(to: CGPoint(x: 20, y: y)); p.addLine(to: CGPoint(x: 20 + w, y: y))
                                }.stroke(YS.line, lineWidth: 1)
                                Text("\(s)").font(.system(size: 8)).foregroundStyle(YS.dim)
                                    .position(x: 9, y: y)
                            }
                            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                                let x = 20 + w * CGFloat(min(16, max(0, p.hours)) / 16)
                                let y = h - h * CGFloat(Double(p.focus - 1) / 4)
                                Circle().fill(YS.violet).frame(width: 7, height: 7)
                                    .position(x: x, y: y)
                            }
                        }
                    }
                    .frame(height: 120)
                    HStack {
                        Text("0 小时").font(.system(size: 10)).foregroundStyle(YS.dim)
                        Spacer()
                        Text("16 小时").font(.system(size: 10)).foregroundStyle(YS.dim)
                    }
                    .padding(.leading, 20)
                }
            } else if let f = store.stats.averageFocus(days: range) {
                Card(title: "专注度", systemImage: "scope") {
                    Text("平均 \(String(format: "%.1f", f.mean)) / 5，共 \(f.count) 次评分")
                        .font(.system(size: 14))
                    Text("再多记几次，这里会画出「服药后第几小时最专注」的散点图。")
                        .font(.system(size: 11)).foregroundStyle(YS.dim)
                }
            } else {
                Card(title: "专注度", systemImage: "scope") {
                    Text("还没有效果记录。在「记录」页给某次服药打个分，就能看出药在第几小时最管用。")
                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                }
            }
        }
    }
}
