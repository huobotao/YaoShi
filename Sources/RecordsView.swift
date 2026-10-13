import SwiftUI

/// 记录页：一条竖直时间轴，服药和效果混在一起按时间倒序排。
struct RecordsView: View {
    @EnvironmentObject var store: Store
    @State private var editingDose: Dose? = nil
    @State private var editingClonidine: ClonidineEntry? = nil
    @State private var editingEffect: EffectLog? = nil
    @State private var newDose = false
    @State private var newEffect = false
    @State private var newNote: EffectLog? = nil
    @State private var editingLife: LifeEvent? = nil
    @State private var lifeDeleteFailed = false

    private enum Item: Identifiable {
        case dose(Dose), clonidine(ClonidineEntry), effect(EffectLog), life(LifeEvent)
        var id: String {
            switch self {
            case .dose(let d): return "d" + d.id.uuidString
            case .clonidine(let d): return "c" + d.id.uuidString
            case .effect(let e): return "e" + e.id.uuidString
            case .life(let e): return "l" + e.id.uuidString
            }
        }
        var at: Date {
            switch self {
            case .dose(let d): return d.at
            case .clonidine(let d): return d.at
            case .effect(let e): return e.at
            case .life(let e): return e.at
            }
        }
        var day: DateOnly { DateOnly(at) }
    }

    private var groups: [(DateOnly, [Item])] {
        let items = store.doses.map { Item.dose($0) } + store.clonidineEntries.map { Item.clonidine($0) }
            + store.effects.map { Item.effect($0) }
            + store.lifeEvents.map { Item.life($0) }
        let byDay = Dictionary(grouping: items) { $0.day }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!.sorted { $0.at > $1.at }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 34)).foregroundStyle(YS.dim)
                        Text("还没有记录").font(.system(size: 16, weight: .semibold))
                        Text("在「今天」页记录服药，或添加一条感受笔记。")
                            .font(.system(size: 13)).foregroundStyle(YS.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(YS.bg)
                } else {
                    List {
                        ForEach(groups, id: \.0) { day, items in
                            Section {
                                ForEach(items) { item in
                                    row(item)
                                        .listRowBackground(YS.card)
                                        .listRowSeparatorTint(YS.line)
                                }
                                .onDelete { idx in remove(items, idx) }
                            } header: {
                                HStack {
                                    Text("\(day.displayFull) \(day.weekdayCN)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(YS.dim)
                                    Spacer()
                                    let n = items.filter { if case .dose = $0 { return true }; return false }.count
                                    if n > 0 {
                                        Text("服药 \(n) 次").font(.system(size: 11))
                                            .foregroundStyle(YS.teal)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(YS.bg)
                }
            }
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newDose = true } label: { Label("补一次服药", systemImage: "pills.fill") }
                        Button { editingClonidine = ClonidineEntry(at: Date(), mg: .zero) } label: { Label("补记可乐定", systemImage: "pills") }
                        Button { newNote = EffectLog(at: Date()) } label: { Label("添加笔记", systemImage: "square.and.pencil") }
                        Button { newEffect = true } label: { Label("记一次效果", systemImage: "chart.line.uptrend.xyaxis") }
                        ForEach(LifeEventKind.allCases) { kind in
                            Button { editingLife = LifeEvent(at: Date(), kind: kind) } label: {
                                Label("记录" + kind.label, systemImage: kind.symbol)
                            }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(item: $editingDose) { d in
            DoseEditor(dose: d) { store.update($0) } onDelete: { store.delete($0) }
        }
        .sheet(item: $editingClonidine) { entry in
            ClonidineEntryEditor(entry: entry, onSave: { store.updateClonidine($0) },
                                 onDelete: { store.deleteClonidine($0) })
        }
        .sheet(item: $editingEffect) { e in
            if e.isNoteOnly {
                NoteEditor(log: e, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            } else {
                EffectEditor(log: e, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            }
        }
        .sheet(isPresented: $newDose) {
            DoseEditor(dose: Dose(at: Date(), mg: store.settings.defaultMg, pillCount: 1)) {
                store.add($0)
            } onDelete: { _ in }
        }
        .sheet(item: $newNote) { log in
            NoteEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { _ in false }
        }
        .sheet(isPresented: $newEffect) {
            EffectEditor(log: EffectLog(at: Date()), doses: store.doses) {
                store.add($0)
            } onDelete: { _ in false }
        }
        .sheet(item: $editingLife) { event in
            LifeEventEditor(event: event, onSave: { store.saveLifeEvent($0) },
                            onDelete: store.lifeEvents.contains(where: { $0.id == event.id }) ? { store.delete($0) } : nil)
        }
        .alert("未能删除记录", isPresented: $lifeDeleteFailed) {
            Button("好", role: .cancel) {}
        } message: { Text(store.storageMessage) }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .life(let e):
            Button { editingLife = e } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(YS.amber.opacity(0.18)).frame(width: 30, height: 30)
                        Image(systemName: e.kind.symbol).font(.system(size: 12)).foregroundStyle(YS.amber)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(Fmt.hm(e.at)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            Text(e.kind.label).font(.system(size: 12)).foregroundStyle(YS.amber)
                        }
                        if !e.note.isEmpty {
                            Text(e.note).font(.system(size: 12)).foregroundStyle(YS.dim).lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(YS.dim)
                }
            }.buttonStyle(.plain).foregroundStyle(YS.text)
        case .dose(let d):
            Button { editingDose = d } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(YS.teal.opacity(0.18)).frame(width: 30, height: 30)
                        Image(systemName: "pills.fill").font(.system(size: 13)).foregroundStyle(YS.teal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(Fmt.hm(d.at)).font(.system(size: 16, weight: .bold)).monospacedDigit()
                            Text("\(d.mg) 毫克").font(.system(size: 12)).foregroundStyle(YS.dim)
                            if d.food != .unknown {
                                Text(d.food.label).font(.system(size: 11))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(YS.card2, in: Capsule()).foregroundStyle(YS.dim)
                            }
                        }
                        if !d.reasonText.isEmpty {
                            Text(d.reasonText).font(.system(size: 12)).foregroundStyle(YS.dim)
                        }
                        if !d.note.isEmpty {
                            Text(d.note).font(.system(size: 12)).foregroundStyle(YS.dim).lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain).foregroundStyle(YS.text)

        case .clonidine(let d):
            Button { editingClonidine = d } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(YS.violet.opacity(0.18)).frame(width: 30, height: 30)
                        Image(systemName: "pills").font(.system(size: 13)).foregroundStyle(YS.violet)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(Fmt.hm(d.at)).font(.system(size: 16, weight: .bold)).monospacedDigit()
                            Text("可乐定 · \(d.doseText) 毫克").font(.system(size: 12)).foregroundStyle(YS.dim)
                        }
                        if !d.note.isEmpty {
                            Text(d.note).font(.system(size: 12)).foregroundStyle(YS.dim).lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain).foregroundStyle(YS.text)

        case .effect(let e):
            Button { editingEffect = e } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(YS.violet.opacity(0.18)).frame(width: 30, height: 30)
                        Image(systemName: e.isNoteOnly ? "note.text" : "chart.line.uptrend.xyaxis").font(.system(size: 12))
                            .foregroundStyle(YS.violet)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(Fmt.hm(e.at)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            Text(e.isNoteOnly ? "感受笔记" : "效果记录")
                                .font(.system(size: 11)).foregroundStyle(YS.dim)
                            if e.focus > 0 {
                                HStack(spacing: 2) {
                                    ForEach(1...5, id: \.self) { i in
                                        Image(systemName: i <= e.focus ? "star.fill" : "star")
                                            .font(.system(size: 9))
                                            .foregroundStyle(i <= e.focus ? YS.amber : YS.dim.opacity(0.4))
                                    }
                                }
                            }
                        }
                        if !e.sides.isEmpty {
                            Text(e.sides.map(\.label).joined(separator: "、"))
                                .font(.system(size: 12)).foregroundStyle(YS.orange)
                        }
                        if !e.note.isEmpty {
                            Text(e.note).font(.system(size: 12)).foregroundStyle(YS.dim).lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain).foregroundStyle(YS.text)
        }
    }

    private func remove(_ items: [Item], _ idx: IndexSet) {
        for i in idx {
            switch items[i] {
            case .dose(let d): store.delete(d)
            case .clonidine(let d): _ = store.deleteClonidine(d)
            case .effect(let e): store.delete(e)
            case .life(let e): if !store.delete(e) { lifeDeleteFailed = true }
            }
        }
    }
}
