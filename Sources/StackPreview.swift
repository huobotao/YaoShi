import SwiftUI

/// 按粒数预演；每粒剂量沿用设置，不写入服药记录。
struct StackPreview: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var pillCount = 1
    @State private var statisticsTime = Date()
    @State private var simulationDate = Date()
    @State private var assumedOffset: TimeInterval = 0

    private var assumedAt: Date { simulationDate.addingTimeInterval(assumedOffset) }
    private var assumedTimeBinding: Binding<Date> {
        Binding(get: { assumedAt }, set: { setAssumedAt($0) })
    }

    private func setAssumedAt(_ date: Date) {
        let offset = date.timeIntervalSince(simulationDate)
        guard offset.isFinite else { return }
        assumedOffset = max(0, offset)
    }

    private var offsetText: String {
        let hours = floor(assumedOffset / 3600)
        let minutes = floor(assumedOffset.truncatingRemainder(dividingBy: 3600) / 60)
        return String(format: "T + %.0f 小时 %.0f 分", hours, minutes)
    }

    private var mg: Int { pillCount * store.settings.defaultMg }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    inputCard
                    resultCards(mg)
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(YS.bg.ignoresSafeArea())
            .navigationTitle("模拟服药时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("按粒数模拟，使用设置里的每粒剂量。不会记成实际服药。")
                    .font(.system(size: 13)).foregroundStyle(YS.dim)
                Stepper(value: $pillCount, in: 1...100) {
                    Text("模拟 \(pillCount) 粒")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .accessibilityIdentifier("hypotheticalPillCount")
                Divider().overlay(YS.line)
                Text("T = 打开模拟时 · \(Fmt.mdhm(simulationDate))")
                    .font(.system(size: 11)).foregroundStyle(YS.dim)
                DatePicker("假想服药", selection: assumedTimeBinding,
                           in: simulationDate..., displayedComponents: [.date, .hourAndMinute])
                    .font(.system(size: 13))
                    .accessibilityIdentifier("hypotheticalDoseTime")
                HStack(spacing: 12) {
                    Button("−1 小时") { assumedOffset = max(0, assumedOffset - 3600) }
                        .disabled(assumedOffset == 0)
                    Spacer(minLength: 0)
                    Text(offsetText).monospacedDigit().foregroundStyle(YS.amber)
                    Spacer(minLength: 0)
                    Button("+1 小时") { assumedOffset += 3600 }
                }
                .font(.system(size: 12, weight: .medium))
                Button("回到 T（现在）") { assumedOffset = 0 }
                    .font(.system(size: 12))
                Text("也可在图中选“移动模拟时间”，拖动时间线预演。")
                    .font(.system(size: 11)).foregroundStyle(YS.dim)
            }
        }
    }

    private func resultCards(_ mg: Int) -> some View {
        let now = simulationDate
        let model = DoseComparisonModel(doses: store.doses, mg: mg, now: now, assumedAt: assumedAt,
                                        curve: store.settings.plasmaCurve)
        let checkpoints: [(String, Date)] = [
            ("现在 T", now), ("假想服药时", assumedAt),
            ("服药后 2h", assumedAt.addingTimeInterval(2 * 3600)),
            ("服药后 6h", assumedAt.addingTimeInterval(6 * 3600)),
            ("服药后 12h", assumedAt.addingTimeInterval(12 * 3600))
        ]
        return VStack(spacing: 14) {
            Card {
                DoseComparisonChart(model: model, onAssumedAtChange: setAssumedAt,
                                    selectedTime: statisticsTime,
                                    onSelectedTimeChange: { statisticsTime = $0 })
            }
            Card {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    DoseAveragePanel(doses: store.doses, mgPerPill: store.settings.defaultMg,
                                     now: context.date, anchor: $statisticsTime)
                }
            }
            Card(title: "同一时刻的模型估算") {
                VStack(spacing: 11) {
                    HStack {
                        Text("时间").frame(maxWidth: .infinity, alignment: .leading)
                        Text("不加新剂").frame(width: 68, alignment: .trailing)
                        Text("模拟后").frame(width: 66, alignment: .trailing)
                        Text("差值").frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(YS.dim)
                    ForEach(checkpoints, id: \.0) { label, at in
                        let levels = model.levels(at: at)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(label)
                                Text(Fmt.mdhm(at)).font(.system(size: 9)).foregroundStyle(YS.dim)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(DoseCurveModel.levelText(levels.withoutDose))
                                .frame(width: 68, alignment: .trailing)
                            Text(DoseCurveModel.levelText(levels.withDose))
                                .foregroundStyle(YS.amber)
                                .frame(width: 66, alignment: .trailing)
                            Text(String(format: "+%.2f 倍", levels.withDose - levels.withoutDose))
                                .foregroundStyle(YS.teal)
                                .frame(width: 58, alignment: .trailing)
                        }
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        if label != "服药后 12h" { Divider().overlay(YS.line) }
                    }
                    Text("1.0 倍为单次 50 毫克的模型峰值；数值不是实测血药浓度。")
                        .font(.system(size: 10)).foregroundStyle(YS.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footnote: some View {
        Text("这是按通用药代参数绘制的模型估算，不代表你的个人血药浓度，也不判断是否适合服药。关闭页面不会保存模拟剂量。")
            .font(.system(size: 11)).foregroundStyle(YS.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
