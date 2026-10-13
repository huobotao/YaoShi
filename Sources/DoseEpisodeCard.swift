import SwiftUI

struct DoseEpisodeCard: View {
    @EnvironmentObject var store: Store
    @State private var choosingStart = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let episode = DoseEpisode(doses: store.doses, selection: store.doseEpisode,
                                      now: context.date,
                                      newRoundGapHours: store.settings.newRoundGapHours)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("距这一波首次服药已过", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YS.teal)
                    if let first = episode.start {
                        Text(Fmt.elapsed(context.date.timeIntervalSince(first.at)))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(YS.text)
                            .accessibilityIdentifier("timeSinceEpisodeStart")
                            .accessibilityLabel("距这一波首次服药已过 " + Fmt.elapsed(context.date.timeIntervalSince(first.at)))
                        Text("首次：\(Fmt.mdhm(first.at)) · \(first.mg) 毫克")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                        HStack(alignment: .firstTextBaseline) {
                            Text("从此起点已记录 \(episode.doses.count) 次服药")
                                .font(.system(size: 12)).foregroundStyle(YS.dim)
                            Spacer(minLength: 8)
                            chooseButton("更换起点")
                        }
                        Text(episode.autoStarted
                             ? "两次实记服药间隔超过设置值，已从这次记录自动开启新一轮。"
                             : "两次实记服药间隔超过 \(store.settings.newRoundGapHours) 小时，后一笔自动开启新一轮。")
                            .font(.system(size: 11)).foregroundStyle(YS.dim)
                    } else {
                        Text(store.doseEpisode?.doseID == nil ? "尚未选择起点" : "请重新选择起点")
                            .font(.system(size: 24, weight: .bold)).foregroundStyle(YS.text)
                        Text(store.doseEpisode?.doseID == nil
                             ? "选出这一波的第一次服药，之后持续累计。"
                             : "原起点记录已删除或时间无效，计时暂不可用。")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                        if store.doses.contains(where: { $0.at <= context.date }) {
                            chooseButton("选择首次服药")
                        } else {
                            Text("有实际服药记录后即可选择。")
                                .font(.system(size: 12)).foregroundStyle(YS.dim)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $choosingStart) {
            DoseEpisodePicker().environmentObject(store)
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["YAOSHI_PREVIEW_EPISODE"] == "1" { choosingStart = true }
            #endif
        }
    }

    private func chooseButton(_ title: String) -> some View {
        Button { choosingStart = true } label: {
            Label(title, systemImage: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(YS.teal)
        .accessibilityIdentifier("chooseEpisodeStart")
    }
}

struct DoseEpisodePicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var saveFailed = false

    private var candidates: [Dose] {
        store.doses.filter { $0.at <= Date() }.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at > $1.at
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("相邻两次实记服药间隔超过 \(store.settings.newRoundGapHours) 小时后，后一笔自动成为新一轮起点。你也可以在这里手动调整起点。")
                        .font(.system(size: 14)).foregroundStyle(YS.dim)
                }
                Section("首次服药") {
                    ForEach(candidates) { dose in
                        Button {
                            selected = dose.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(Fmt.mdhm(dose.at)).foregroundStyle(YS.text)
                                    Text("\(dose.med) · \(dose.mg) 毫克")
                                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                                }
                                Spacer()
                                Image(systemName: selected == dose.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected == dose.id ? YS.teal : YS.dim)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == dose.id ? .isSelected : [])
                        .accessibilityIdentifier("episodeDose-" + dose.id.uuidString)
                    }
                }
                if store.doseEpisode?.doseID != nil {
                    Section {
                        Button("清除当前起点", role: .destructive) {
                            save(nil)
                        }
                    } footer: {
                        Text("仅清除计时起点，保留所有服药记录。")
                    }
                }
                Section {
                    Text("这是按记录计算的时间，不表示持续药效、未进食或未入睡。")
                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle("这一波从哪次开始")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(selected) }
                        .fontWeight(.semibold)
                        .disabled(!candidates.contains { $0.id == selected })
                        .accessibilityIdentifier("saveEpisodeStart")
                }
            }
            .onAppear {
                selected = DoseEpisode(doses: store.doses, selection: store.doseEpisode,
                                       now: Date(),
                                       newRoundGapHours: store.settings.newRoundGapHours).start?.id
            }
            .alert("未能保存起点", isPresented: $saveFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请检查所选服药记录是否仍然存在，稍后重试。原起点未改变。")
            }
        }
    }

    private func save(_ id: UUID?) {
        if store.selectDoseEpisode(startingAt: id) { dismiss() } else { saveFailed = true }
    }
}
