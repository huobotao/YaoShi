import SwiftUI

/// A duration-based window; midnight and daylight-saving changes do not reset it.
struct DoseWindowCard: View {
    @EnvironmentObject var store: Store
    @AppStorage("doseWindow.durationHours") private var durationHours = 24.0
    @AppStorage("doseWindow.referenceHours") private var referenceHours = 24.0
    @AppStorage("doseWindow.shiftHours") private var shiftHours = 24.0
    @State private var pinnedEnd: Date?
    @State private var dragOrigin: Date?
    @State private var showControls = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let summary = DoseWindowSummary(doses: store.doses, end: pinnedEnd ?? now,
                durationHours: durationHours, referenceHours: referenceHours,
                mgPerPill: store.settings.defaultMg, now: now)
            Card(title: "滑动窗口 · 服药统计", systemImage: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(number(summary.normalizedPills))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundStyle(YS.teal)
                            .accessibilityIdentifier("doseWindowAverage")
                        Text("颗 / \(hours(summary.referenceHours)) 小时")
                            .font(.system(size: 13)).foregroundStyle(YS.dim)
                        Spacer(minLength: 0)
                    }
                    Text("\(hours(summary.durationHours)) 小时内：\(number(summary.totalPills)) 颗 · \(summary.totalMg) mg · \(summary.doseCount) 次记录")
                        .font(.system(size: 12)).foregroundStyle(YS.text)
                        .accessibilityIdentifier("doseWindowTotal")
                    Text("\(dateText(summary.start)) → \(dateText(summary.end))\(pinnedEnd == nil ? " · 现在" : "")")
                        .font(.system(size: 11)).foregroundStyle(YS.dim)
                        .accessibilityIdentifier("doseWindowRange")
                    timeline(summary, now: now)
                    HStack {
                        Button { moveEnd(by: -shiftHours, now: now) } label: {
                            Label("往前", systemImage: "chevron.left")
                        }.accessibilityIdentifier("doseWindowEarlier")
                        Spacer()
                        Button("回到现在") { pinnedEnd = nil }
                            .accessibilityIdentifier("doseWindowNow")
                        Spacer()
                        Button { moveEnd(by: shiftHours, now: now) } label: {
                            Label("往后", systemImage: "chevron.right")
                        }
                        .disabled(pinnedEnd == nil)
                        .accessibilityIdentifier("doseWindowLater")
                    }
                    .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(YS.teal)
                    DisclosureGroup("调整窗口与统计单位", isExpanded: $showControls) {
                        controls(now: now)
                    }
                    .font(.system(size: 12)).tint(YS.teal)
                    if summary.estimatedDoseCount > 0 {
                        Text("含 \(summary.estimatedDoseCount) 条未保存颗数的旧记录，按每颗 \(store.settings.defaultMg) mg 折算，颗数及平均值为估算。")
                            .font(.system(size: 11)).foregroundStyle(YS.amber)
                    }
                    Text(summary.doseCount == 0 ? "此窗口内没有记录，不代表没有服药。" : "平均值 = 窗口内颗数 ÷ 窗口小时数 × 统计单位小时数。仅统计已记录内容。")
                        .font(.system(size: 11)).foregroundStyle(YS.dim)
                }
            }
        }
    }

    private func timeline(_ summary: DoseWindowSummary, now: Date) -> some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(YS.teal.opacity(0.08))
                Rectangle().fill(YS.line).frame(height: 1)
                ForEach(summary.recordedDoses) { dose in
                    let fraction = dose.at.timeIntervalSince(summary.start) / (summary.durationHours * 3600)
                    Capsule().fill(YS.teal).frame(width: 4, height: 19)
                        .position(x: 4 + max(0, min(1, fraction)) * max(1, geometry.size.width - 8), y: 20)
                }
                VStack { Spacer(); Text("左右拖动时间窗口").font(.system(size: 9)).foregroundStyle(YS.dim) }
                    .padding(.bottom, 3)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if dragOrigin == nil { dragOrigin = pinnedEnd ?? now }
                    let shift = -Double(value.translation.width / max(1, geometry.size.width)) * summary.durationHours * 3600
                    pinnedEnd = min(now, (dragOrigin ?? now).addingTimeInterval(shift))
                }
                .onEnded { _ in
                    dragOrigin = nil
                    if let end = pinnedEnd, end >= now { pinnedEnd = nil }
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("服药时间窗口")
            .accessibilityValue("\(dateText(summary.start)) 到 \(dateText(summary.end))")
            .accessibilityAdjustableAction { direction in
                moveEnd(by: direction == .increment ? shiftHours : -shiftHours, now: now)
            }
        }
        .frame(height: 48)
    }

    private func controls(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ForEach([24.0, 72.0, 168.0], id: \.self) { value in
                    Button(value == 168 ? "7 天" : "\(Int(value)) 小时") { durationHours = value }
                        .buttonStyle(.bordered).tint(durationHours == value ? YS.teal : YS.dim)
                }
            }
            hourControl("窗口长度", value: $durationHours, limit: 8760)
            hourControl("平均每多少小时", value: $referenceHours, limit: 8760)
            hourControl("按钮每次移动", value: $shiftHours, limit: 8760)
            DatePicker("窗口截止", selection: Binding(
                get: { min(pinnedEnd ?? now, now) },
                set: { pinnedEnd = min($0, now) }), in: ...now,
                displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            Text("默认截止到现在；拖动、按钮或日期选择会固定截止时间。点击「回到现在」恢复跟随。")
                .font(.system(size: 11)).foregroundStyle(YS.dim)
        }
        .padding(.top, 8)
    }

    private func hourControl(_ label: String, value: Binding<Double>, limit: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("小时", value: value, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing).frame(width: 65)
                .textFieldStyle(.roundedBorder)
                .onSubmit { value.wrappedValue = clamp(value.wrappedValue, limit: limit) }
            Text("小时").foregroundStyle(YS.dim)
            Stepper(label, value: value, in: 1...limit, step: 1).labelsHidden()
        }
        .onChange(of: value.wrappedValue) { _, newValue in
            let valid = clamp(newValue, limit: limit)
            if newValue != valid { value.wrappedValue = valid }
        }
    }

    private func moveEnd(by hours: Double, now: Date) {
        let end = (pinnedEnd ?? now).addingTimeInterval(hours * 3600)
        pinnedEnd = end >= now ? nil : end
    }

    private func clamp(_ value: Double, limit: Double) -> Double {
        value.isFinite ? min(limit, max(1, value)) : 24
    }
    private func number(_ value: Double) -> String { String(format: "%.2f", value) }
    private func hours(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    private func dateText(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: value)
    }
}
