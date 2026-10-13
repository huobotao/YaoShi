import SwiftUI

/// 按粒数预演；每粒剂量沿用设置，不写入服药记录。
struct StackPreview: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var pillCount = 1
    @State private var simulationDate = Date()

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
            .navigationTitle("模拟现在服药")
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
            }
        }
    }

    private func resultCards(_ mg: Int) -> some View {
        let now = simulationDate
        let model = DoseComparisonModel(doses: store.activeStack(at: now), mg: mg, now: now,
                                        curve: store.settings.plasmaCurve)
        let checkpoints: [(String, TimeInterval)] = [
            ("现在", 0), ("2 小时后", 2 * 3600), ("6 小时后", 6 * 3600), ("12 小时后", 12 * 3600)
        ]
        return VStack(spacing: 14) {
            Card {
                DoseComparisonChart(model: model)
            }
            Card(title: "同一时刻的模型估算") {
                VStack(spacing: 11) {
                    HStack {
                        Text("时间").frame(width: 52, alignment: .leading)
                        Text("不加新剂").frame(width: 68, alignment: .trailing)
                        Text("模拟后").frame(width: 66, alignment: .trailing)
                        Text("差值").frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(YS.dim)
                    ForEach(checkpoints, id: \.0) { label, interval in
                        let levels = model.levels(after: interval)
                        HStack {
                            Text(label).frame(width: 52, alignment: .leading)
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
                        if label != "12 小时后" { Divider().overlay(YS.line) }
                    }
                    Text("1.0 倍为单次 40 毫克的模型峰值；数值不是实测血药浓度。")
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
