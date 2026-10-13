import SwiftUI

struct LifeTimersCard: View {
    @EnvironmentObject var store: Store
    @State private var editing: LifeEvent?
    @State private var justAddedID: UUID?
    private var justAdded: LifeEvent? { store.lifeEvents.first { $0.id == justAddedID } }
    @State private var storageFailed = false

    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let timeline = LifeTimeline(events: store.lifeEvents, now: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    Label("这一轮 · 睡眠与进食", systemImage: "bed.double.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(YS.text)
                    let episode = DoseEpisode(doses: store.doses, selection: store.doseEpisode,
                                              now: context.date,
                                              newRoundGapHours: store.settings.newRoundGapHours)
                    if let start = episode.start {
                        episodeSummary(timeline: timeline, start: start.at)
                    } else {
                        Text("在上方选择本轮首次服药，即可汇总这一轮的睡眠与进食。")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                    Divider().overlay(YS.line)
                    timer(title: "距上次入睡", event: timeline.lastSleep, now: context.date,
                          symbol: "moon.zzz.fill", color: YS.violet, identifier: "timeSinceLastSleep")
                    if let wake = timeline.awakeSince {
                        Text("距已记录起床 \(Fmt.elapsed(context.date.timeIntervalSince(wake))) · \(Fmt.mdhm(wake))")
                            .accessibilityIdentifier("timeAwake")
                            .font(.system(size: 12)).foregroundStyle(YS.teal)
                    } else if timeline.lastSleep != nil {
                        Text("这次入睡后尚无起床记录，时长待补记。")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    } else {
                        Text("补记实际入睡、起床时间，也可以记录小睡。")
                            .font(.system(size: 12)).foregroundStyle(YS.dim)
                    }
                    HStack(spacing: 10) {
                        action("记入睡", symbol: "moon.fill", color: YS.violet) {
                            editing = LifeEvent(at: Date(), kind: .sleep)
                        }.accessibilityIdentifier("recordSleep")
                        action("记起床", symbol: "sun.max.fill", color: YS.teal) {
                            editing = LifeEvent(at: Date(), kind: .wake)
                        }.accessibilityIdentifier("recordWake")
                    }
                    if let latest = timeline.sleeps.last {
                        Text("最近完整睡眠：\(Fmt.elapsed(latest.duration))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(YS.violet)
                            .accessibilityIdentifier("lastSleepDuration")
                        HStack {
                            Button("入睡 \(Fmt.mdhm(latest.sleep.at))") { editing = latest.sleep }
                            Spacer(minLength: 4)
                            Button("起床 \(Fmt.mdhm(latest.wake.at))") { editing = latest.wake }
                        }.font(.system(size: 11)).foregroundStyle(YS.dim)
                    }
                    Divider().overlay(YS.line)
                    timer(title: "距上次吃东西", event: timeline.lastFood, now: context.date,
                          symbol: "fork.knife", color: YS.amber, identifier: "timeSinceLastFood")
                    Text("正餐、零食，吃一点也算。")
                        .font(.system(size: 12)).foregroundStyle(YS.dim)
                    HStack(spacing: 10) {
                        action("刚吃了东西", symbol: "plus", color: YS.amber) { recordFood() }
                            .accessibilityIdentifier("recordFoodNow")
                        action("补记进食", symbol: "clock.arrow.circlepath", color: YS.dim) {
                            editing = LifeEvent(at: Date(), kind: .food)
                        }
                    }

                    Text("按已记录的实际时间累计，跨天不归零。点时间可更正。")
                        .font(.system(size: 11)).foregroundStyle(YS.dim)
                }
            }
            if let event = justAdded {
                Divider().overlay(YS.line)
                HStack {
                    Text("已记下 \(Fmt.hm(event.at)) 进食")
                        .font(.system(size: 12)).foregroundStyle(YS.amber)
                    Spacer()
                    Button("修改") { editing = event }
                    Button("撤销") {
                        if store.delete(event) { justAddedID = nil } else { storageFailed = true }
                    }
                }.font(.system(size: 12, weight: .semibold))
            }
        }
        .sheet(item: $editing) { event in
            LifeEventEditor(event: event, onSave: {
                let saved = store.saveLifeEvent($0)
                if saved, justAddedID == $0.id { justAddedID = nil }
                return saved
            }, onDelete: !store.lifeEvents.contains(where: { $0.id == event.id }) ? nil : {
                let saved = store.delete($0)
                if saved, justAddedID == $0.id { justAddedID = nil }
                return saved
            })
        }
        .alert("暂时无法保存", isPresented: $storageFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.storageMessage)
        }
    }

    @ViewBuilder
    private func episodeSummary(timeline: LifeTimeline, start: Date) -> some View {
        let records = timeline.events(since: start)
        let foods = records.filter { $0.kind == .food }
        let sleepDuration = timeline.recordedSleep(since: start)
        VStack(alignment: .leading, spacing: 8) {
            Text("从首次服药 \(Fmt.mdhm(start)) 起")
                .font(.system(size: 12)).foregroundStyle(YS.dim)
            HStack(alignment: .top) {
                Label("已记录进食 \(foods.count) 次", systemImage: "fork.knife")
                    .foregroundStyle(YS.amber)
                Spacer()
                Label(sleepDuration > 0 ? "已记录睡眠 \(Fmt.elapsed(sleepDuration))" : "未记录完整睡眠", systemImage: "moon.fill")
                    .foregroundStyle(YS.violet)
            }
            .font(.system(size: 13, weight: .semibold))
            .accessibilityIdentifier("episodeLifeSummary")
            if records.isEmpty {
                Text("此轮暂无生活记录。吃了一点、睡了一小会儿，都可以在下面记下。")
                    .font(.system(size: 12)).foregroundStyle(YS.dim)
            }
            if let sleep = timeline.lastSleep, sleep.at >= start,
               timeline.lastWake == nil || timeline.lastWake!.at <= sleep.at {
                Text("已记录入睡 \(Fmt.mdhm(sleep.at))，补记起床后计算时长。")
                    .font(.system(size: 12)).foregroundStyle(YS.violet)
            }
            ForEach(Array(records.prefix(5))) { event in
                Button { editing = event } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.kind.symbol).frame(width: 18)
                        Text("\(Fmt.mdhm(event.at)) · \(event.kind.label)")
                        if !event.note.isEmpty { Text(event.note).lineLimit(1) }
                        Spacer(minLength: 0)
                        Image(systemName: "pencil").font(.system(size: 10))
                    }.font(.system(size: 12)).foregroundStyle(YS.text)
                        .padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if records.count > 5 {
                Text("显示最近 5 条，全部记录可在“记录”中查看。")
                    .font(.system(size: 11)).foregroundStyle(YS.dim)
            }
            Text("睡眠只累计已配对的入睡与起床，跨起点只计本轮部分；未记录不代表没睡或没吃。")
                .font(.system(size: 11)).foregroundStyle(YS.dim)
        }
    }

    private func recordFood() {
        let event = LifeEvent(at: Date(), kind: .food)
        if store.saveLifeEvent(event) {
            justAddedID = event.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else { storageFailed = true }
    }

    private func action(_ title: String, symbol: String, color: Color,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(color)
        }.buttonStyle(.plain)
    }

    private func timer(title: String, event: LifeEvent?, now: Date, symbol: String,
                       color: Color, identifier: String) -> some View {
        Button {
            editing = event ?? LifeEvent(at: Date(), kind: identifier == "timeSinceLastFood" ? .food : .sleep)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(YS.dim)
                }
                Text(event.map { Fmt.elapsed(now.timeIntervalSince($0.at)) } ?? "未记录")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(YS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier(identifier)
                if let event {
                    Text("上次：\(Fmt.mdhm(event.at))")
                        .font(.system(size: 11)).foregroundStyle(YS.dim)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
