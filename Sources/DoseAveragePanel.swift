import SwiftUI

/// A movable time anchor and a fixed-duration window over recorded doses.
/// The enclosing screen supplies the card and the same anchor used by its chart.
struct DoseAveragePanel: View {
    let doses: [Dose]
    let mgPerPill: Int
    let now: Date
    @Binding var anchor: Date

    @State private var window: DoseAverageWindow = .week
    @State private var direction: DoseAverageDirection = .backward
    @State private var dragOrigin: Date?

    private let hourSpacing: CGFloat = 28

    private var summary: DoseAverageSummary {
        DoseAverageSummary(doses: doses, anchor: anchor, now: now,
                           window: window, direction: direction, mgPerPill: mgPerPill)
    }

    var body: some View {
        let result = summary
        VStack(alignment: .leading, spacing: 14) {
            Label("平均每 24 小时服药", systemImage: "pills")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YS.text)

            VStack(alignment: .leading, spacing: 8) {
                Text("时间 T · \(dateText(anchor))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(YS.teal)
                    .accessibilityIdentifier("doseAverageAnchor")
                timeRuler
                HStack {
                    shiftButton("−24 小时", hours: -24, id: "doseAveragePreviousDay")
                    Spacer(minLength: 4)
                    Button("回到现在") { anchor = now }
                        .accessibilityIdentifier("doseAverageNow")
                    Spacer(minLength: 4)
                    shiftButton("+24 小时", hours: 24, id: "doseAverageNextDay")
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(YS.teal)
                Text("左右滑动刻度选择 T · 每格 1 小时，精确到分钟")
                    .font(.system(size: 11)).foregroundStyle(YS.dim)
                DatePicker("精确选择 T", selection: $anchor,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.system(size: 12))
                    .tint(YS.teal)
                    .accessibilityIdentifier("doseAverageDatePicker")
            }

            Picker("统计时长", selection: $window) {
                Text(DoseAverageWindow.day.label).tag(DoseAverageWindow.day)
                Text(DoseAverageWindow.week.label).tag(DoseAverageWindow.week)
                Text(DoseAverageWindow.fortnight.label).tag(DoseAverageWindow.fortnight)
                Text(DoseAverageWindow.fourWeeks.label).tag(DoseAverageWindow.fourWeeks)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("doseAverageWindow")

            Picker("相对 T 的方向", selection: $direction) {
                Text(DoseAverageDirection.backward.label).tag(DoseAverageDirection.backward)
                Text(DoseAverageDirection.forward.label).tag(DoseAverageDirection.forward)
                Text(DoseAverageDirection.centered.label).tag(DoseAverageDirection.centered)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("doseAverageDirection")

            if direction == .centered {
                Text("前后：以 T 为中心，总时长各分一半。")
                    .font(.system(size: 11)).foregroundStyle(YS.dim)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.recordCount > 0 ? (result.averagePer24Hours.map { String(format: "%.2f", $0) } ?? "—") : "—")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .foregroundStyle(YS.teal)
                        .accessibilityIdentifier("doseAverageValue")
                    Text("粒 / 24 小时")
                        .font(.system(size: 14)).foregroundStyle(YS.dim)
                }
                Text("已记录合计 \(mgPerPill > 0 ? String(format: "%.2f", result.totalPills) : "—") 粒 · \(result.recordCount) 次服药")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(YS.text)
                    .accessibilityIdentifier("doseAverageTotal")
                Text("起：\(dateText(result.start))\n止：\(dateText(result.end))")
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(YS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("doseAverageInterval")
            }

            if result.containsFuture {
                note("区间尚未结束，暂不显示完整区间平均值；未来服药尚未知。", color: YS.amber)
            }
            if result.recordCount == 0 {
                note("此区间尚无实际服药记录，不代表确认未服药。", color: YS.dim)
            }
            if let first = doses.filter({ $0.at <= now }).map(\.at).min(), result.start < first {
                note("区间开始早于首条记录，完整性未确认。", color: YS.amber)
            }
            if mgPerPill <= 0 {
                note("请先在设置中填写有效的每粒剂量。", color: YS.amber)
            }
            if result.invalidDoseCount > 0 {
                note("\(result.invalidDoseCount) 条剂量无效的记录未参与计算。", color: YS.amber)
            }
            if result.estimatedDoseCount > 0 {
                note("其中 \(result.estimatedDoseCount) 条旧记录未记颗数，按当前每粒 \(mgPerPill) 毫克估算。", color: YS.dim)
            }
            note("优先使用记录的颗数；仅统计实际服药，模拟不计入。", color: YS.dim)
        }
        .accessibilityIdentifier("doseAveragePanel")
    }

    private var timeRuler: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let anchorHours = anchor.timeIntervalSince1970 / 3600
            let baseHour = floor(anchorHours)
            let radius = Int(ceil(geometry.size.width / hourSpacing / 2)) + 2
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(YS.card2)
                ForEach(-radius...radius, id: \.self) { offset in
                    let hour = baseHour + Double(offset)
                    let position = center + CGFloat(hour - anchorHours) * hourSpacing
                    let tickDate = Date(timeIntervalSince1970: hour * 3600)
                    let isMajor = Int(hour).isMultiple(of: 3)
                    VStack(spacing: 5) {
                        Rectangle()
                            .fill(isMajor ? YS.dim : YS.dim.opacity(0.45))
                            .frame(width: 1, height: isMajor ? 22 : 12)
                            .frame(height: 22, alignment: .top)
                        if isMajor {
                            Text(Fmt.hm(tickDate))
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(YS.dim)
                        }
                    }
                    .frame(width: 52, height: 46, alignment: .top)
                    .position(x: position, y: 31)
                }
                Rectangle().fill(YS.teal).frame(width: 2, height: 46)
                    .position(x: center, y: 27)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard dragOrigin != nil || abs(value.translation.width) > abs(value.translation.height) else { return }
                    if dragOrigin == nil { dragOrigin = anchor }
                    guard let origin = dragOrigin else { return }
                    let seconds = -Double(value.translation.width / hourSpacing) * 3600
                    let timestamp = origin.timeIntervalSince1970 + seconds
                    anchor = Date(timeIntervalSince1970: (timestamp / 60).rounded() * 60)
                }
                .onEnded { _ in dragOrigin = nil })
        }
        .frame(height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间 T 滚轮")
        .accessibilityValue(dateText(anchor))
        .accessibilityHint("左滑查看较晚时间，右滑查看较早时间；调整操作每次移动一小时")
        .accessibilityAdjustableAction { adjustment in
            switch adjustment {
            case .increment: anchor = anchor.addingTimeInterval(3600)
            case .decrement: anchor = anchor.addingTimeInterval(-3600)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("doseAverageRuler")
    }

    private func shiftButton(_ title: String, hours: Double, id: String) -> some View {
        Button(title) { anchor = anchor.addingTimeInterval(hours * 3600) }
            .padding(.vertical, 8)
            .accessibilityIdentifier(id)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
