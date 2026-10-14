import SwiftUI

struct TodayView: View {
    @EnvironmentObject var store: Store
    @State private var showDetail = false
    @State private var showCurveAnalysis = false
    @State private var showStackPreview = false
    @State private var editing: Dose? = nil
    @State private var editingNote: EffectLog? = nil

    private var todayNotes: [EffectLog] {
        store.effects.filter { $0.dateOnly == .today() && !$0.note.isEmpty }
            .sorted { $0.at > $1.at }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    dashboardContent(width: geometry.size.width)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .background(YS.bg.ignoresSafeArea())
            .navigationTitle("药时 2.10.12 · 后台 R3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editingNote = EffectLog(at: Date()) } label: {
                        Label("添加笔记", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("addFeelingNoteToolbar")
                }
            }
        }
        .sheet(item: $editing) { d in
            DoseEditor(dose: d) { store.update($0) } onDelete: { store.delete($0) }
        }
        .sheet(isPresented: $showStackPreview) {
            StackPreview().environmentObject(store)
        }
        .sheet(item: $editingNote) { log in
            if log.isNoteOnly {
                NoteEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            } else {
                EffectEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            }
        }
        .fullScreenCover(isPresented: $showCurveAnalysis) {
            DoseCurveAnalysisView().environmentObject(store)
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["YAOSHI_PREVIEW_NOTE"] == "1", editingNote == nil {
                editingNote = EffectLog(at: Date())
            }
            #endif
        }
    }

    /// Use available window width so iPad Split View also falls back to the phone layout.
    @ViewBuilder
    private func dashboardContent(width: CGFloat) -> some View {
        if width >= 900 {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 14) {
                    gapCard
                    DoseWindowCard()
                    quickButton
                    if let d = store.lastQuickAdded { justAddedBar(d) }
                    todayCard
                    if !store.storageOK { warningCard }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 14) {
                    DoseEpisodeCard()
                    LifeTimersCard()
                    notesCard
                }
                .frame(width: min(420, (min(width, 1200) - 50) * 0.40))
            }
            .frame(maxWidth: 1168)
        } else {
            VStack(spacing: 14) {
                gapCard
                DoseWindowCard()
                quickButton
                if let d = store.lastQuickAdded { justAddedBar(d) }
                DoseEpisodeCard()
                LifeTimersCard()
                notesCard
                todayCard
                if !store.storageOK { warningCard }
            }
            .frame(maxWidth: 720)
        }
    }

    // MARK: 距上次服药

    private var gapCard: some View {
        Card {
            let st = store.status
            if let last = st.lastDoseAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = ctx.date.timeIntervalSince(last)
                    let hours = secs / 3600
                    // 感受这一层按最近一次服药算：第二片真正做的是再制造一次上升，
                    // 不是把效果翻倍，所以阶段和剩余时间都跟着最后那一片走。
                    let phase = DoseEngine.phase(hoursSinceDose: hours)
                    let stack = store.activeStack(at: ctx.date)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("距上次服药已过").font(.system(size: 13)).foregroundStyle(YS.dim)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Fmt.elapsed(secs))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                                .foregroundStyle(YS.text)
                                .accessibilityIdentifier("timeSinceLastDose")
                                .accessibilityLabel("距上次服药已过 " + Fmt.elapsed(secs))
                            Spacer(minLength: 0)
                            InventoryInlineButton()
                        }

                        HStack(spacing: 8) {
                            Label(phase == .over ? "估算时段结束" : "参考：" + phase.label, systemImage: phase.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(YS.color(phase).opacity(0.18), in: Capsule())
                                .foregroundStyle(YS.color(phase))
                            Text("\(Fmt.mdhm(last)) · \(st.lastMg) 毫克")
                                .font(.system(size: 12)).foregroundStyle(YS.dim)
                        }
                        Text("通用模型参考，实际感受以你的记录为准。").font(.system(size: 12)).foregroundStyle(YS.dim)

                        LevelBar(level: DoseEngine.remaining(hoursSinceDose: hours), phase: phase)
                            .padding(.top, 2)
                        HStack {
                            if let left = DoseEngine.remainingText(hoursSinceDose: hours) {
                                Text(left).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(YS.color(phase))
                            } else {
                                Text("已超出常用药效估算时段").font(.system(size: 12)).foregroundStyle(YS.dim)
                            }
                            Spacer()
                            if phase != .over {
                                Text("参考结束：\(Fmt.hm(DoseEngine.endTime(of: Dose(at: last, mg: st.lastMg))))")
                                    .font(.system(size: 12)).foregroundStyle(YS.dim)
                            }
                        }

                        // 数字和曲线共享同一时刻、同一份模型结果。
                        let episode = DoseEpisode(doses: store.doses, selection: store.doseEpisode, now: ctx.date,
                                                  newRoundGapHours: store.settings.newRoundGapHours)
                        let curve = DoseCurveModel(doses: store.doses, now: ctx.date,
                                                   curve: store.settings.plasmaCurve)
                        Divider().overlay(YS.line).padding(.vertical, 2)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("现在相对浓度 · 模型估算").font(.system(size: 12)).foregroundStyle(YS.dim)
                            Spacer(minLength: 4)
                            Text(DoseCurveModel.levelText(curve.currentLevel))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .accessibilityIdentifier("currentPlasmaEstimate")
                        }
                        DoseCurve(model: curve, phase: phase,
                                  annotations: store.effects.filter { !$0.note.isEmpty },
                                  lifeEvents: store.lifeEvents,
                                  episode: episode,
                                  onExpand: { showCurveAnalysis = true },
                                  onEditNote: { editingNote = $0 })
                        if let low = st.plasmaLowAt, low > ctx.date {
                            Text("模型估值降到 0.2 倍，预计 \(Fmt.mdhm(low))")
                                .font(.system(size: 12)).foregroundStyle(YS.dim)
                        }
                        Text("仅按已记录剂量和通用参数计算，不能据此判断是否适合再次服药。")
                            .font(.system(size: 11)).foregroundStyle(YS.dim)

                        Button { showStackPreview = true } label: {
                            Text("模拟现在服药").font(.system(size: 12)).foregroundStyle(YS.teal)
                        }
                        if stack.count > 1 {
                            Text("模型把各次服药的估算浓度相加；主观感受不会按同样比例变化。")
                                .font(.system(size: 11)).foregroundStyle(YS.dim)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("还没有任何服药记录")
                            .font(.system(size: 20, weight: .bold))
                        Spacer(minLength: 0)
                        InventoryInlineButton()
                    }
                    Text("按下面那个大按钮，就记下第一次。以后每次吃完按一下就行。")
                        .font(.system(size: 13)).foregroundStyle(YS.dim)
                }
            }
        }
    }

    // MARK: 快速记录

    private var quickButton: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    let d = store.quickTake()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    // 12 秒后自动收起撤销条
                    Task {
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if store.lastQuickAdded?.id == d.id {
                            withAnimation { store.lastQuickAdded = nil }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "pills.fill").font(.system(size: 22, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("我服药了").font(.system(size: 20, weight: .bold))
                            Text("记下此刻 · 1 粒")
                                .font(.system(size: 11)).opacity(0.85)
                        }
                        Spacer(minLength: 2)
                        Text(Fmt.hm(Date())).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .opacity(0.9)
                    }
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 15).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(
                        LinearGradient(colors: [YS.teal, YS.amber],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .accessibilityIdentifier("primaryMedicationTakeButton")

            }

            HStack(spacing: 10) {
                Button {
                    showDetail = true
                } label: {
                    Label("补记 / 填原因", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(YS.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(YS.line))
                }
                if store.skippedToday {
                    Button {
                        store.unmarkSkipped()
                    } label: {
                        Label("取消不吃", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(YS.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(YS.line))
                    }
                } else if store.status.takenToday == 0 {
                    Button {
                        store.markSkipped()
                    } label: {
                        Label("今天不吃", systemImage: "moon.zzz")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(YS.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(YS.line))
                    }
                }
            }
            .foregroundStyle(YS.text)
        }
        .sheet(isPresented: $showDetail) {
            DoseEditor(dose: Dose(at: Date(), mg: store.settings.defaultMg, pillCount: 1)) {
                store.add($0)
            } onDelete: { _ in }
        }
    }

    private func justAddedBar(_ d: Dose) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(YS.teal)
            Text("已记下 \(Fmt.hm(d.at))").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("补充原因") { editing = d }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(YS.teal)
            Button("撤销") { store.delete(d) }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(YS.red)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(YS.card2, in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 今天

    private var notesCard: some View {
        Card {
            Button { editingNote = EffectLog(at: Date()) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 23)).foregroundStyle(YS.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("添加笔记").font(.system(size: 17, weight: .semibold)).foregroundStyle(YS.text)
                        Text("记下此时此刻的感受").font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 23)).foregroundStyle(YS.teal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addFeelingNote")

            if !todayNotes.isEmpty {
                Divider().overlay(YS.line).padding(.vertical, 3)
                Text("今天的笔记 · \(todayNotes.count) 条")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(YS.dim)
                ForEach(todayNotes) { log in
                    Button { editingNote = log } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(Fmt.hm(log.at)).font(.system(size: 14, weight: .semibold))
                                .monospacedDigit().foregroundStyle(YS.teal)
                            Text(log.note).font(.system(size: 14)).foregroundStyle(YS.text)
                                .lineLimit(3).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 11))
                                .foregroundStyle(YS.dim).padding(.top, 3)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var todayCard: some View {
        Card(title: "今天", systemImage: "sun.max.fill") {
            let today = store.doses.filter { $0.dateOnly == .today() }.sorted { $0.at < $1.at }
            if store.skippedToday {
                Text("今天标记为不吃\(store.dayLog(for: .today()).skipReason.isEmpty ? "" : "（\(store.dayLog(for: .today()).skipReason)）")")
                    .font(.system(size: 14)).foregroundStyle(YS.violet)
            } else if today.isEmpty {
                Text("今天没有服药记录")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YS.dim)
            } else {
                let todayMg = today.reduce(0) { $0 + $1.mg }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("已服 \(today.count) 次").font(.system(size: 15, weight: .semibold))
                        if today.count > 1 {
                            Text("共 \(todayMg) 毫克")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YS.dim)
                        }
                    }
                    if todayMg > DoseEngine.labelMaxDailyMg {
                        Text("说明书参考：澳洲注册说明书上成人的最大推荐日剂量是 \(DoseEngine.labelMaxDailyMg) 毫克，超过这个量的有效性与安全性没有做过研究。你的处方可能与这个参考值不同，以医生的医嘱为准。")
                            .font(.system(size: 11)).foregroundStyle(YS.dim)
                    }
                    ForEach(today) { d in
                        Button { editing = d } label: {
                            HStack(spacing: 10) {
                                Text(Fmt.hm(d.at)).font(.system(size: 15, weight: .bold))
                                    .monospacedDigit().foregroundStyle(YS.teal)
                                Text("\(d.mg) 毫克").font(.system(size: 13)).foregroundStyle(YS.dim)
                                if !d.reasonText.isEmpty {
                                    Text(d.reasonText).font(.system(size: 12))
                                        .foregroundStyle(YS.dim).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11))
                                    .foregroundStyle(YS.dim)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain).foregroundStyle(YS.text)
                    }
                }
            }
        }
    }

    private var warningCard: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(YS.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("存储异常").font(.system(size: 14, weight: .bold)).foregroundStyle(YS.red)
                    Text(store.storageMessage).font(.system(size: 12)).foregroundStyle(YS.dim)
                }
            }
        }
    }
}
