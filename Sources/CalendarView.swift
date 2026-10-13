import SwiftUI

/// 日历页：一个月一眼看完——哪天吃了、几点吃的、哪天漏了、哪天主动没吃。
struct CalendarPage: View {
    @EnvironmentObject var store: Store
    @State private var anchor = Date()           // 当前显示的月份
    @State private var selected: DateOnly = .today()
    @State private var editing: Dose? = nil
    @State private var editingEffect: EffectLog? = nil

    private let cal = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    monthCard
                    legend
                    dayCard
                    monthStats
                }
                .frame(maxWidth: 800)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .background(YS.bg.ignoresSafeArea())
            .navigationTitle("日历")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $editing) { d in
            DoseEditor(dose: d) { store.update($0) } onDelete: { store.delete($0) }
        }
        .sheet(item: $editingEffect) { log in
            if log.isNoteOnly {
                NoteEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            } else {
                EffectEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            }
        }
    }

    // MARK: 月历

    private var monthCard: some View {
        Card {
            VStack(spacing: 12) {
                HStack {
                    Button { shift(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Text(monthTitle).font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button { shift(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(isCurrentMonth)
                    .opacity(isCurrentMonth ? 0.3 : 1)
                }
                .foregroundStyle(YS.text)

                HStack(spacing: 0) {
                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { w in
                        Text(w).font(.system(size: 11)).foregroundStyle(YS.dim)
                            .frame(maxWidth: .infinity)
                    }
                }

                let grid = monthGrid
                VStack(spacing: 6) {
                    ForEach(0..<(grid.count / 7), id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { col in
                                let cell = grid[row * 7 + col]
                                dayCell(cell)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: DateOnly?) -> some View {
        Group {
            if let day {
                let ds = store.doses.filter { $0.dateOnly == day }.sorted { $0.at < $1.at }
                let skipped = store.days.first { $0.date == day }?.skipped == true
                let isToday = day == .today()
                let isFuture = day > .today()
                let isSel = day == selected

                VStack(spacing: 2) {
                    Text("\(day.d)")
                        .font(.system(size: 13, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isFuture ? YS.dim.opacity(0.35) : YS.text)
                    if let first = ds.first {
                        Text(Fmt.hm(first.at))
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(hourColor(first.hourOfDay))
                        if ds.count > 1 {
                            Text("×\(ds.count)").font(.system(size: 8)).foregroundStyle(YS.dim)
                        }
                    } else if skipped {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 9))
                            .foregroundStyle(YS.violet)
                    } else if !isFuture {
                        Circle().fill(YS.dim.opacity(0.25)).frame(width: 4, height: 4)
                    } else {
                        Spacer().frame(height: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(ds.isEmpty ? Color.clear : hourColor(ds[0].hourOfDay).opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(isSel ? YS.teal : (isToday ? YS.amber.opacity(0.7) : .clear),
                                lineWidth: isSel ? 1.6 : 1.2)
                )
                .contentShape(Rectangle())
                .onTapGesture { selected = day }
            } else {
                Color.clear.frame(height: 42).frame(maxWidth: .infinity)
            }
        }
    }

    /// 服药时刻的颜色：越早越接近青色，越晚越接近红色
    private func hourColor(_ h: Double) -> Color {
        switch h {
        case ..<9:    return YS.teal
        case ..<11:   return YS.amber
        case ..<14:   return YS.orange
        default:      return YS.red
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([("9 点前", YS.teal), ("9–11 点", YS.amber),
                     ("11–14 点", YS.orange), ("更晚", YS.red)], id: \.0) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0).font(.system(size: 10)).foregroundStyle(YS.dim)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: 选中那天

    private var dayCard: some View {
        Card(title: "\(selected.displayFull) \(selected.weekdayCN)", systemImage: "calendar") {
            let ds = store.doses.filter { $0.dateOnly == selected }.sorted { $0.at < $1.at }
            let es = store.effects.filter { $0.dateOnly == selected }.sorted { $0.at < $1.at }
            let log = store.days.first { $0.date == selected }

            VStack(alignment: .leading, spacing: 10) {
                if ds.isEmpty && es.isEmpty {
                    Text(log?.skipped == true ? "这天标记为不吃" : "这天没有记录")
                        .font(.system(size: 13)).foregroundStyle(YS.dim)
                }
                ForEach(ds) { d in
                    Button { editing = d } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "pills.fill").font(.system(size: 13))
                                .foregroundStyle(hourColor(d.hourOfDay))
                            Text(Fmt.hm(d.at)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                            Text("\(d.mg) 毫克").font(.system(size: 12)).foregroundStyle(YS.dim)
                            if !d.reasonText.isEmpty {
                                Text(d.reasonText).font(.system(size: 12))
                                    .foregroundStyle(YS.dim).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10))
                                .foregroundStyle(YS.dim)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(YS.text)
                }
                ForEach(es) { e in
                    Button { editingEffect = e } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Image(systemName: e.isNoteOnly ? "note.text" : "chart.line.uptrend.xyaxis")
                                    .font(.system(size: 12)).foregroundStyle(YS.violet)
                                Text(Fmt.hm(e.at)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                Text(e.isNoteOnly ? "感受笔记" : "效果记录")
                                    .font(.system(size: 11)).foregroundStyle(YS.dim)
                                if e.focus > 0 {
                                    Text("专注 \(e.focus)/5").font(.system(size: 12)).foregroundStyle(YS.dim)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(YS.dim)
                            }
                            if !e.sides.isEmpty {
                                Text(e.sides.map(\.label).joined(separator: "、"))
                                    .font(.system(size: 11)).foregroundStyle(YS.orange).lineLimit(1)
                            }
                            if !e.note.isEmpty {
                                Text(e.note).font(.system(size: 13)).foregroundStyle(YS.dim)
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain).foregroundStyle(YS.text)
                }
            }
        }
    }

    // MARK: 本月小结

    private var monthStats: some View {
        Card(title: "本月", systemImage: "chart.bar.fill") {
            let comps = cal.dateComponents([.year, .month], from: anchor)
            let inMonth = store.doses.filter {
                let c = cal.dateComponents([.year, .month], from: $0.at)
                return c.year == comps.year && c.month == comps.month
            }
            let dayCount = Set(inMonth.map { $0.dateOnly.id }).count
            let hours = inMonth.map(\.hourOfDay).filter { $0 >= 4 }
            let mean = hours.isEmpty ? 0 : hours.reduce(0, +) / Double(hours.count)

            HStack(spacing: 22) {
                stat("\(dayCount)", "天有服药")
                stat("\(inMonth.count)", "次总计")
                if !hours.isEmpty { stat(Fmt.hour(mean), "平均时刻") }
                Spacer()
            }
        }
    }

    private func stat(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            Text(small).font(.system(size: 11)).foregroundStyle(YS.dim)
        }
    }

    // MARK: 日期计算

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "yyyy 年 M 月"
        return f.string(from: anchor)
    }

    private var isCurrentMonth: Bool {
        cal.isDate(anchor, equalTo: Date(), toGranularity: .month)
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: anchor) { anchor = d }
    }

    /// 补齐成整周的格子，空位是 nil
    private var monthGrid: [DateOnly?] {
        guard let range = cal.range(of: .day, in: .month, for: anchor),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: anchor))
        else { return [] }
        let leading = cal.component(.weekday, from: first) - 1
        var out: [DateOnly?] = Array(repeating: nil, count: leading)
        for d in range { out.append(DateOnly(cal.date(byAdding: .day, value: d - 1, to: first) ?? first)) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }
}
