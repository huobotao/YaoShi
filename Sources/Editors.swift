import SwiftUI

// MARK: - 服药记录编辑

struct DoseEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var dose: Dose
    /// 保存回调。新建和修改都走这里，由外面决定是 add 还是 update。
    var onSave: (Dose) -> Void
    var onDelete: (Dose) -> Void

    @State private var confirmDelete = false
    private var isNew: Bool { dose.updatedAt == nil }
    // Never reinterpret a legacy milligram record as a known number of pills.
    private var pillCount: Int? {
        dose.pillCount
    }

    private func setPillCount(_ count: Int) {
        dose.pillCount = count
        dose.mg = count * store.settings.defaultMg
    }


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("服药时刻", selection: $dose.at)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    if let count = pillCount {
                        Stepper("数量 \(count) 粒", value: Binding(
                            get: { pillCount ?? 1 },
                            set: { setPillCount($0) }
                        ), in: 1...100)
                        .accessibilityIdentifier("dosePillCount")
                    } else {
                        HStack {
                            Text("数量")
                            Spacer()
                            Text("未记录 · 原剂量 \(dose.mg) 毫克").foregroundStyle(YS.dim)
                        }
                        Button("重新按粒设置：1 粒") { setPillCount(1) }
                            .accessibilityIdentifier("resetDosePillCount")
                    }
                    Picker("是否随餐", selection: $dose.food) {
                        ForEach(FoodState.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("时间与数量")
                } footer: {
                    Text(isNew ? "每粒剂量在「我的」中设置。" : "只改时间或备注会保留原剂量和颗数。调整数量会按当前每粒 \(store.settings.defaultMg) 毫克重新计算剂量；旧记录未记颗数时不自动换算。")
                }

                Section("为什么吃（可多选，也可以不填）") {
                    let cols = [GridItem(.adaptive(minimum: 92), spacing: 8)]
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(DoseReason.allCases) { r in
                            let on = dose.reasons.contains(r)
                            Button {
                                if on { dose.reasons.removeAll { $0 == r } } else { dose.reasons.append(r) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: r.symbol).font(.system(size: 11))
                                    Text(r.label).font(.system(size: 13))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(on ? YS.teal.opacity(0.22) : YS.card2,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(on ? YS.teal : YS.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("备注") {
                    TextField("想记的任何事", text: $dose.note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("删除这条记录", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle(isNew ? "补记一次服药" : "修改记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(dose); dismiss() }.fontWeight(.semibold)
                }
            }
            .alert("删除这条服药记录？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { onDelete(dose); dismiss() }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

// MARK: - 效果记录编辑

struct EffectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var log: EffectLog
    var doses: [Dose]
    var onSave: (EffectLog) -> Bool
    var onDelete: (EffectLog) -> Bool

    @State private var confirmDelete = false
    @State private var storageFailed = false
    private var isNew: Bool { log.updatedAt == nil }

    /// 24 小时内可关联的服药
    private var candidates: [Dose] {
        doses.filter { $0.at <= log.at && log.at.timeIntervalSince($0.at) < 24 * 3600 }
            .sorted { $0.at > $1.at }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("时间") {
                    DatePicker("记录时刻", selection: $log.at)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    if let d = candidates.first {
                        let h = log.at.timeIntervalSince(d.at) / 3600
                        Text("对应 \(Fmt.hm(d.at)) 那次服药之后 \(Fmt.gap(h * 3600))")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                }

                Section("专注程度") {
                    VStack(alignment: .leading, spacing: 6) {
                        Stars(value: $log.focus, tint: YS.amber)
                        Text(focusHint).font(.system(size: 11)).foregroundStyle(YS.dim)
                    }
                    .padding(.vertical, 4)
                }

                Section("情绪状态") {
                    Stars(value: $log.mood, tint: YS.teal).padding(.vertical, 4)
                }

                Section("有没有不舒服（可多选）") {
                    let cols = [GridItem(.adaptive(minimum: 92), spacing: 8)]
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(SideEffect.allCases) { s in
                            let on = log.sides.contains(s)
                            Button {
                                if on { log.sides.removeAll { $0 == s } } else { log.sides.append(s) }
                            } label: {
                                Text(s.label).font(.system(size: 13))
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(on ? YS.orange.opacity(0.22) : YS.card2,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(on ? YS.orange : YS.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("备注") {
                    TextField("这一阵子怎么样", text: $log.note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("删除这条记录", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle(isNew ? "记一次效果" : "修改效果记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if onSave(log) { dismiss() } else { storageFailed = true }
                    }.fontWeight(.semibold)
                }
            }
            .alert("删除这条效果记录？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    if onDelete(log) { dismiss() } else { storageFailed = true }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("暂时无法保存", isPresented: $storageFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("内容仍保留在本页，请稍后重试。")
            }
        }
    }

    private var focusHint: String {
        switch log.focus {
        case 1: return "完全坐不住，什么都做不进去"
        case 2: return "勉强能开始，很快就跑神"
        case 3: return "一般，能做事但要反复拉回来"
        case 4: return "挺顺，能连着做一段"
        case 5: return "非常专注，一口气做完"
        default: return "点星星打分。这个分数以后会跟服药时刻对上，看出药在第几小时最管用。"
        }
    }
}

// MARK: - 当下感受笔记

struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var log: EffectLog
    var doses: [Dose]
    var onSave: (EffectLog) -> Bool
    var onDelete: (EffectLog) -> Bool
    @FocusState private var writing: Bool
    @State private var confirmDelete = false
    @State private var storageFailed = false

    private var isNew: Bool { log.updatedAt == nil }
    private var isEmpty: Bool { log.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var relatedDose: Dose? {
        doses.filter { $0.at <= log.at && log.at.timeIntervalSince($0.at) < 24 * 3600 }
            .max { $0.at < $1.at }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("比如：这会儿药效挺好，做事很专注，心情也轻松。", text: $log.note, axis: .vertical)
                        .lineLimit(6...12)
                        .focused($writing)
                        .accessibilityIdentifier("feelingNoteText")
                } header: {
                    Text("此时此刻，我感觉如何？")
                } footer: {
                    Text("可以用键盘上的麦克风口述，想记什么就写什么。")
                }
                Section("记录时刻") {
                    DatePicker("时间", selection: $log.at, in: ...Date())
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    if let dose = relatedDose {
                        Text("距 \(Fmt.hm(dose.at)) 那次服药 \(Fmt.gap(log.at.timeIntervalSince(dose.at)))")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("删除这条笔记", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle(isNew ? "添加笔记" : "感受笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var saved = log
                        saved.note = saved.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if onSave(saved) { dismiss() } else { storageFailed = true }
                    }
                    .fontWeight(.semibold)
                    .disabled(isEmpty)
                    .accessibilityIdentifier("saveFeelingNote")
                }
            }
            .interactiveDismissDisabled(!isEmpty)
            .onAppear { if isNew { writing = true } }
            .alert("删除这条笔记？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    if onDelete(log) { dismiss() } else { storageFailed = true }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("暂时无法保存", isPresented: $storageFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("笔记仍保留在本页，请稍后重试。")
            }
        }
    }
}
